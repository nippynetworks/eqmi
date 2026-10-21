# Eqmi

QMI (Qualcomm MSM Interface) client implementation in Elixir

### Request / response in one call

`Eqmi.query/5` encodes a request for the client's service, waits for the
matching response and returns the TLV parameters as a map. The "result" TLV is
returned as the function result:

```
iex> {:ok, dev} = Eqmi.device("/dev/cdc-wdm0")
iex> nas = Eqmi.client(dev, :qmi_nas)
iex> Eqmi.query(dev, nas, :get_signal_info)
{:ok, %{lte_signal_strength: %{rsrp: -111, rsrq: -14, rssi: -82, snr: 34}}}

iex> wds = Eqmi.client(dev, :qmi_wds)
iex> Eqmi.query(dev, wds, :get_current_settings, requested_settings: 0xFFFFFFFF)
{:error, {:qmi, :out_of_call, %{result: %{error_status: 1, error_code: 15}}}}
```

Errors are of the form `{:error, {:qmi, reason, params}}` with the reason
as per libqmi (`Eqmi.Error.protocol/1`)
`params` shows the complete TLV of the response,
so a failed `:start_network` has a `verbose_call_end_reason`,
which `Eqmi.Error.verbose_call_end_reason/1` will translate into:
`{:internal, :interface_in_use_config_match}`.
Indications are still delivered to the client's mailbox as `{:qmux, msg}`.

The sections below show the lower-level `send_message/3` flow.

### Parameters

A message's parameters are the TLV names of the libqmi spec in `priv/`,
lower-cased with underscores, so `Eqmi.describe/2` is the reference:

```
iex> Eqmi.describe(:qmi_nas, :get_signal_strength)
%{name: :get_signal_strength, id: 32, type: :message,
  input: [%{name: :request_mask, id: 16, format: "guint16"}],
  output: [%{name: :result, ...}, %{name: :signal_strength, format: "sequence",
            fields: [%{name: :strength, ...}, %{name: :radio_interface, ...}]}, ...]}
iex> Eqmi.messages(:qmi_dms) |> Enum.map(& &1.name)
[:reset, :set_event_report, :get_capabilities, ...]
```

A few "get" messages only return what the request asks for. NAS Get
Signal Strength needs `request_mask` (bit 0 RSSI, 1 ECIO, 2 IO, 3 SINR,
4 error rate, 5 RSRQ, 6 LTE SNR, 7 LTE RSRP) or the modem answers with the
mandatory `signal_strength` TLV alone, and WDS Get Current Settings needs
`requested_settings`. `Eqmi.query/5` fills these in (`request_mask: 0xFF`,
`requested_settings: 0xFFFFFFFF`, see `Eqmi.query_defaults/2`) unless you
pass the key yourself; `request/2` and `call/4` send exactly what they are
given. For a periodic signal poll prefer NAS Get Signal Info, which needs
no mask and reports every radio in one TLV.

### Clients

The modem allocates a client ID (CID) per service and keeps state per
client: a data call belongs to the WDS client that started it, indication
registrations belong to the client that made them. CIDs are a scarce
resource on the modem (it reports `client_ids_exhausted` when the pool for
a service runs out), so:

* **One device per VM.** `Eqmi.device/1` opens a path once and every
  caller shares it. Only one operating-system process can read a cdc-wdm
  device at a time: a second reader (another VM, or qmicli without
  qmi-proxy) steals responses and its CTL sync releases every client the
  first process holds.
* **Plain queries use the shared client.** `Eqmi.query(dev, :qmi_nas, ...)`
  uses a client the device allocates once per service and owns itself.
* **Allocate your own client for state.** `Eqmi.client/2` gives a client
  owned by the calling process: use it for data calls and for anything that
  registers indications, and keep it for as long as that state matters.
  Indications arrive in the owner's mailbox as `{:qmux, msg}`.
* **Release is automatic.** A client is released on the modem when its
  owner process exits, when `Eqmi.release_client/2` is called, and for
  every client when the device stops (`Eqmi.close/1`, application
  shutdown, SIGTERM). Clients leaked by a killed VM are released by the
  CTL sync the next open performs.
* **Requests do not need separate clients.** The device serialises writes
  and matches responses by client and transaction id, so any number of
  processes can send requests through one client concurrently.

Avoid opening and closing the device repeatedly (one process per request,
as a qmicli wrapper does): cdc-wdm keeps unread data across close and
reopen, and rapid open/close cycles have wedged the kernel driver in ways
only a reboot clears.

### WDS control point

This example shows how to stablish a data connection similar to

```
qmicli --device=/dev/cdc-wdm0 --device-open-proxy --wds-start-network="ip-type=4,apn=my.isp.com" --client-no-release-cid
```

Initialization

```
iex(1)>  {:ok, dev} = Eqmi.device("/dev/cdc-wdm0")
{:ok, #PID<0.199.0>}
```

Create a control point for WDS

```
iex(2)> client = Eqmi.client(dev, :qmi_wds)
#Reference<0.1318031025.2560360450.258300>
```

Create start network message

```
iex(3)> msg = Eqmi.WDS.request(:start_network, [{:apn, "my.isp.com"},{:ip_family_preference, 4}])
<<32, 0, ..., 99, 108>>
```

Send message

```
iex(4)> Eqmi.send_message(dev, client, [msg])
:ok
iex(5)>flush
{:qmux,
 %{
   client_id: 20,
   message_type: :response,
   messages: [
     %{
       msg_id: 32,
       name: :start_network,
       parameters: %{
         packet_data_handle: 2688802694,
         result: %{error_code: 0, error_status: 0}
       }
     }
   ],
   sender_type: :service,
   service_type: :qmi_wds,
   tx_id: 1
 }}
{:qmux,
 %{
   client_id: 20,
   message_type: :indication,
   messages: [
     %{
       msg_id: 34,
       name: :packet_service_status,
       parameters: %{
         connection_status: %{reconfiguration_required: 0, status: 2},
         ip_family: 4,
         bearer_id: 5,
         unknown: %{19 => <<128, 136>>}
       }
     }
   ],
   sender_type: :service,
   service_type: :qmi_wds,
   tx_id: 1
 }}
:ok
```

and sending a dhcp request:

```
$ sudo udhcpc -q -f -n -i wwan0
udhcpc: started, v1.30.1
udhcpc: sending discover
udhcpc: sending select for 10.9.173.23
udhcpc: lease of 10.9.173.23 obtained, lease time 7200
```

to change qmi_wwan driver to use Raw-IP

```
echo Y > /sys/class/net/wwan0/qmi/raw_ip
```

Each decoded message carries its spec `name`, and `parameters` is a map
keyed by TLV name. TLVs the spec does not know (or whose payload does not
match it) are kept as raw bytes under `:unknown`, by TLV id.

### NAS control point

This example shows how to retrieve signal information

Create control point for WDS

```
iex(2)> client = Eqmi.client(dev, :qmi_nas)
#Reference<0.2220104178.776208385.43591>
```

Create get_signal_info message

```
iex(4)> msg = Eqmi.NAS.request(:get_signal_info,[])
<<79, 0, 0, 0>>
```

Send message

```
iex(5)> Eqmi.send_message(dev, client, [msg])
:ok
iex(6)> flush
{:qmux,
 %{
   client_id: 2,
   message_type: :response,
   messages: [
     %{
       msg_id: 79,
       name: :get_signal_info,
       parameters: %{
         lte_signal_strength: %{rsrp: -111, rsrq: -14, rssi: -82, snr: 34},
         result: %{error_code: 0, error_status: 0}
       }
     }
   ],
   sender_type: :service,
   service_type: :qmi_nas,
   tx_id: 1
 }}
:ok
```
