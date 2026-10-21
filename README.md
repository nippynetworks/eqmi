# Eqmi

QMI (Qualcomm MSM Interface) client implementation in Elixir

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
