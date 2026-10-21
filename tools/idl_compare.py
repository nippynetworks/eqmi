#!/usr/bin/env python3
"""Compare eqmi's libqmi JSON specs with Qualcomm QMI IDL tables.

Usage: tools/idl_compare.py <dir with *_v01.c/.h> priv

The IDL sources are the generated qmi_idl tables shipped in Android/CodeAurora
trees, e.g. https://github.com/os-vector/wire-os/tree/main/qmi/services
(network_access_service_v01.c/.h, wireless_data_service_v01.c/.h,
device_management_service_v01.c/.h, common_v01.c, *_common_v01.c).
Rename network_access_service_v01.{c,h} to nas_v01_services.{c,h} or adjust
SERVICES below. Only NAS, WDS and DMS are compared; messages and TLVs are
matched by id and direction and the flattened wire layout of shared TLVs is
compared (same-size field swaps are not detected).
"""
"""
import json, re, sys, os, collections

W = sys.argv[1]; PRIV = sys.argv[2]

# ---------------------------------------------------------------- IDL parsing
def split_top(body):
    """split a C initializer body on commas outside parentheses"""
    out, depth, cur = [], 0, []
    for ch in body:
        if ch == '(': depth += 1
        elif ch == ')': depth -= 1
        if ch == ',' and depth == 0:
            out.append(''.join(cur).strip()); cur = []
        else:
            cur.append(ch)
    tail = ''.join(cur).strip()
    if tail: out.append(tail)
    return [t for t in out if t]

def strip_comments(src):
    return re.sub(r'/\*.*?\*/', '', src, flags=re.S)

FIELD_RE = re.compile(r'QMI_IDL_OFFSET\w*\(\s*\w+\s*,\s*(\w+)\s*\)')

def parse_entries(tokens, with_tlv_ids):
    """Parse a data table into a list of fields (or (tlv_id, field) when with_tlv_ids)."""
    fields, i, tlv = [], 0, None
    while i < len(tokens):
        t = tokens[i]
        if t == 'QMI_IDL_FLAG_END_VALUE': break
        if 'QMI_IDL_TLV_FLAGS_OPTIONAL' in t:
            i += 1; continue
        m = re.fullmatch(r'(?:QMI_IDL_TLV_FLAGS_LAST_TLV\s*\|\s*)?(0x[0-9A-Fa-f]+)', t)
        if m and with_tlv_ids:
            tlv = int(m.group(1), 16); i += 1; continue
        flags = t; i += 1
        if 'QMI_IDL_FLAGS_FIRST_EXTENDED' in flags:
            flags += ' ' + tokens[i]; i += 1
        mm = FIELD_RE.search(tokens[i])
        if not mm:
            raise ValueError(f"unexpected token after flags {flags!r}: {tokens[i]!r}; context {tokens[max(0,i-4):i+3]}")
        name = mm.group(1); i += 1
        f = {'name': name, 'flags': flags}
        is_array = 'QMI_IDL_FLAGS_IS_ARRAY' in flags
        var_len = 'QMI_IDL_FLAGS_IS_VARIABLE_LEN' in flags
        sz16 = 'QMI_IDL_FLAGS_SZ_IS_16' in flags
        if is_array:
            if sz16:
                f['count'] = tokens[i]; i += 2
            else:
                f['count'] = tokens[i]; i += 1
            if var_len and 'QMI_IDL_STRING' not in flags:
                i += 1  # len-offset expression
        if 'QMI_IDL_AGGREGATE' in flags:
            m = re.search(r'QMI_IDL_TYPE88\((\d+),\s*(\d+)\)', tokens[i]); i += 1
            f['ref'] = (int(m.group(1)), int(m.group(2)))
        fields.append((tlv, f) if with_tlv_ids else f)
    return fields

def parse_service(cfile, hfile):
    c = strip_comments(open(cfile, encoding='latin-1').read())
    tables = {}
    for m in re.finditer(r'static const uint8_t (\w+)\[\] = \{(.*?)\};', c, re.S):
        tables[m.group(1)] = m.group(2)
    types = []
    m = re.search(r'qmi_idl_type_table_entry\s+(\w+)\[\]\s*=\s*\{(.*?)\};', c, re.S)
    if m:
        for e in re.finditer(r'\{sizeof\((\w+)\),\s*(\w+)\}', m.group(2)):
            types.append((e.group(1), e.group(2)))
    msgs = []
    m = re.search(r'qmi_idl_message_table_entry\s+\w+\[\] = \{(.*?)\};', c, re.S)
    if m:
        for e in re.finditer(r'\{sizeof\((\w+)\),\s*(\w+)\}', m.group(1)):
            msgs.append((e.group(1), e.group(2)))
    refs = []
    m = re.search(r'referenced_tables_v01\[\] =\s*\{(.*?)\};', c, re.S)
    if m:
        refs = [r.strip().lstrip('&').replace('_qmi_idl_type_table_object_v01', '') for r in m.group(1).split(',')]
    cmd = {}
    for kind, pat in (('request', 'command'), ('response', 'response'), ('indication', 'indication')):
        m = re.search(r'service_%s_messages_v01\[\] = \{(.*?)\};' % pat, c, re.S)
        if not m: continue
        for e in re.finditer(r'\{(\w+),\s*QMI_IDL_TYPE16\(\d+,\s*(\d+)\),\s*\d+\}', m.group(1)):
            cmd[(kind, e.group(1))] = int(e.group(2))
    ids = {}
    if hfile and os.path.exists(hfile):
        for m in re.finditer(r'#define (QMI_\w+_V01)\s+(0x[0-9A-Fa-f]+)', open(hfile, encoding='latin-1').read()):
            ids[m.group(1)] = int(m.group(2), 16)
    return {'tables': tables, 'types': types, 'msgs': msgs, 'refs': refs, 'cmd': cmd, 'ids': ids}

SERVICES = {
    'nas': ('nas_v01_services.c', 'nas_v01_services.h'),
    'wds': ('wireless_data_service_v01.c', 'wireless_data_service_v01.h'),
    'dms': ('device_management_service_v01.c', 'device_management_service_v01.h'),
    'common': ('common_v01.c', None),
    'data_common': ('data_common_v01.c', None),
    'network_access_service_common': ('network_access_service_common_v01.c', None),
    'wireless_data_service_common': ('wireless_data_service_common_v01.c', None),
}
IDL = {k: parse_service(os.path.join(W, v[0]), v[1] and os.path.join(W, v[1])) for k, v in SERVICES.items() if os.path.exists(os.path.join(W, v[0]))}

def idl_layout(svc, fields, top):
    """flatten IDL fields to layout tokens + names"""
    toks, names = [], []
    for f in fields:
        flags = f['flags']
        if 'QMI_IDL_AGGREGATE' in flags:
            t, i = f['ref']; ref_svc = IDL[svc]['refs'][t]
            tname, tdata = IDL[ref_svc]['types'][i]
            inner, inner_names = idl_layout(ref_svc, parse_entries(split_top(IDL[ref_svc]['tables'][tdata]), False), False)
            elem = inner
        elif 'QMI_IDL_STRING' in flags:
            elem = ['str' if top else ('str16' if 'SZ_IS_16' in flags else 'str8')]
        else:
            m = re.search(r'(\d)_BYTE', flags); n = int(m.group(1))
            elem = [f'u{n*8}']
        if 'QMI_IDL_FLAGS_IS_ARRAY' in flags and 'QMI_IDL_STRING' not in flags:
            if 'QMI_IDL_FLAGS_IS_VARIABLE_LEN' in flags:
                toks += ['arr16' if 'SZ_IS_16' in flags else 'arr8', '['] + elem + [']']
            else:
                toks += [f"fix{f['count']}", '['] + elem + [']']
        else:
            toks += elem
        names.append(f['name'])
    return toks, names

def idl_messages(svc):
    """{(direction, msg_id): {'name': ..., 'tlvs': {id: (layout, names)}}}"""
    out = {}
    d = IDL[svc]
    for (kind, sym), idx in d['cmd'].items():
        mid = d['ids'].get(sym)
        if mid is None: continue
        sname, tdata = d['msgs'][idx]
        tlvs = {}
        if tdata != '0':
            for tlv, f in parse_entries(split_top(d['tables'][tdata]), True):
                tlvs[tlv] = (idl_layout(svc, [f], True), f['name'])
        out[(kind, mid)] = {'name': sym, 'tlvs': tlvs}
    return out

# ---------------------------------------------------------------- JSON side
def load_json(p):
    raw = open(p).read(); raw = '\n'.join(l for l in raw.splitlines() if not l.strip().startswith('//')); return json.loads(raw)

def json_layout(t, top=True):
    fmt = t.get('format')
    sizes = {'guint8': 'u8', 'gint8': 'u8', 'guint16': 'u16', 'gint16': 'u16', 'guint32': 'u32', 'gint32': 'u32', 'gfloat': 'u32', 'guint64': 'u64', 'gdouble': 'u64'}
    if fmt in sizes: return [sizes[fmt]]
    if fmt == 'guint-sized': return [f"u{int(t['guint-size'])*8}"]
    if fmt == 'string':
        if 'fixed-size' in t: return [f"fix{t['fixed-size']}", '[', 'u8', ']']
        if top and 'size-prefix-format' not in t: return ['str']
        return ['str16' if t.get('size-prefix-format') == 'guint16' else 'str8']
    if fmt in ('sequence', 'struct'):
        out = []
        for c in t['contents']: out += json_layout(c, False)
        return out
    if fmt == 'array':
        elem = json_layout(t['array-element'], False)
        pre = []
        if 'sequence-prefix-format' in t: pre = [sizes[t['sequence-prefix-format']]]
        if 'fixed-size' in t: return pre + [f"fix{t['fixed-size']}", '['] + elem + [']']
        spf = t.get('size-prefix-format', 'guint8')
        return pre + [{'guint8': 'arr8', 'guint16': 'arr16', 'guint32': 'arr32'}[spf], '['] + elem + [']']
    return [f'?{fmt}']

def json_names(t):
    if t.get('format') in ('sequence', 'struct'): return [c.get('name') for c in t['contents']]
    return [t.get('name')]

def json_messages(path, common):
    data = load_json(path)
    defs = {e['common-ref']: e for e in common}
    defs.update({e['common-ref']: e for e in data if 'common-ref' in e})
    out = {}
    for e in data:
        if e.get('type') not in ('Message', 'Indication'): continue
        for dirn, kind in (('input', 'request'), ('output', 'response' if e['type'] == 'Message' else 'indication')):
            tlvs = {}
            for t in e.get(dirn, []):
                if 'common-ref' in t:
                    t = {**defs[t['common-ref']], **{k: v for k, v in t.items() if k != 'common-ref'}}
                tlvs[int(t['id'], 16)] = (json_layout(t), t['name'])
            if e['type'] == 'Message' or dirn == 'output':
                out[(kind, int(e['id'], 16))] = {'name': e['name'], 'tlvs': tlvs}
    return out

# resolve symbolic fixed array counts from the headers (#define NAS_FOO_V01 3)
DEFINES = {}
for k, (cf, hf) in SERVICES.items():
    if hf and os.path.exists(os.path.join(W, hf)):
        for m in re.finditer(r'#define (\w+_V01)\s+(\d+)\b', open(os.path.join(W, hf), encoding='latin-1').read()):
            DEFINES[m.group(1)] = m.group(2)
def norm(toks):
    out = []
    for t in toks:
        if t.startswith('fix'):
            v = t[3:]; out.append('fix' + DEFINES.get(v, v))
        else: out.append(t)
    return out

common = load_json(os.path.join(PRIV, 'qmi-common.json'))
for svc in ('nas', 'wds', 'dms'):
    if svc not in IDL: continue
    idl = idl_messages(svc); js = json_messages(os.path.join(PRIV, f'qmi-service-{svc}.json'), common)
    print(f"\n######## {svc.upper()}: IDL {len(idl)} message tables, JSON {len(js)}")
    missing = sorted(set(idl) - set(js), key=lambda k: (k[0], k[1]))
    print(f"-- messages in IDL but not in JSON ({len(missing)}):")
    for k in missing: print(f"   {k[0]:10} 0x{k[1]:04X} {idl[k]['name']}")
    extra = sorted(set(js) - set(idl), key=lambda k: (k[0], k[1]))
    print(f"-- messages in JSON but not in IDL ({len(extra)}): " + ", ".join(f"{k[0][:3]} 0x{k[1]:04X} {js[k]['name']}" for k in extra))
    print("-- per-message TLV differences (shared messages):")
    for k in sorted(set(idl) & set(js), key=lambda k: (k[1], k[0])):
        a, b = idl[k]['tlvs'], js[k]['tlvs']
        only_idl = sorted(set(a) - set(b)); only_js = sorted(set(b) - set(a))
        diffs = []
        for tid in sorted(set(a) & set(b)):
            (la, na), fa = a[tid]; lb, nb = b[tid]
            if norm(la) != norm(lb): diffs.append((tid, la, na, lb, nb, fa))
        if only_idl or only_js or diffs:
            print(f"   {k[0][:3]} 0x{k[1]:04X} {js[k]['name']}:")
            if only_idl: print("      TLVs only in IDL : " + ", ".join(f"0x{t:02X} {a[t][1]}" for t in only_idl))
            if only_js:  print("      TLVs only in JSON: " + ", ".join(f"0x{t:02X} {b[t][1]}" for t in only_js))
            for tid, la, na, lb, nb, fa in diffs:
                print(f"      LAYOUT 0x{tid:02X} {nb} (idl field {fa}):\n         idl : {' '.join(la)}\n         json: {' '.join(lb)}")
