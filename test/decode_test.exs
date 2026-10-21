defmodule EqmiDecodeTest do
  use ExUnit.Case

  # pure encode -> decode round trips through the generated service modules
  @hdr %{service_type: :qmi_nas, client_id: 3, sender_type: :service}
  @ok [error_status: 0, error_code: 0]

  defp decode(mod, type, msg), do: mod.process_qmux_sdu(mod.qmux_sdu(type, 7, [msg]), @hdr)

  test "response parameters are a map keyed by TLV name" do
    msg =
      Eqmi.NAS.response(:get_signal_info,
        lte_signal_strength: [rssi: -50, rsrq: -14, rsrp: -80, snr: 152],
        result: @ok
      )

    assert %{message_type: :response, tx_id: 7, messages: [message]} = decode(Eqmi.NAS, :response, msg)

    assert message == %{
             msg_id: 0x4F,
             name: :get_signal_info,
             parameters: %{
               lte_signal_strength: %{rssi: -50, rsrq: -14, rsrp: -80, snr: 152},
               result: %{error_status: 0, error_code: 0}
             }
           }
  end

  test "TLVs the spec does not know are kept raw under :unknown by id" do
    <<0x4F, 0, len::little-16, tlvs::binary>> = Eqmi.NAS.response(:get_signal_info, result: @ok)
    extra = <<0xF0, 2::little-16, 1, 2, 0xF1, 1::little-16, 9>>
    msg = <<0x4F, 0, len + byte_size(extra)::little-16, tlvs::binary, extra::binary>>

    assert [%{parameters: params}] = decode(Eqmi.NAS, :response, msg).messages
    assert params.unknown == %{0xF0 => <<1, 2>>, 0xF1 => <<9>>}
    assert params.result == %{error_status: 0, error_code: 0}
  end

  test "a TLV that does not match its spec entry is kept raw instead of failing the message" do
    # lte_signal_strength is 6 bytes; send 2
    msg = <<0x4F, 0, 5::little-16, 0x14, 2::little-16, 0xAA, 0xBB>>

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert [%{parameters: %{unknown: %{0x14 => <<0xAA, 0xBB>>}}}] =
                 decode(Eqmi.NAS, :response, msg).messages
      end)

    assert log =~ "cannot decode TLV 20 of message 79"
  end

  test "messages and indications sharing an id are named by direction" do
    hdr = %{@hdr | service_type: :qmi_wds}
    resp = Eqmi.WDS.response(:get_packet_service_status, connection_status: 2, result: @ok)
    ind = Eqmi.WDS.indication(:packet_service_status, connection_status: [status: 2, reconfiguration_required: 0])

    assert [%{msg_id: 0x22, name: :get_packet_service_status}] =
             Eqmi.WDS.process_qmux_sdu(Eqmi.WDS.qmux_sdu(:response, 1, [resp]), hdr).messages

    assert [%{msg_id: 0x22, name: :packet_service_status, parameters: %{connection_status: %{status: 2}}}] =
             Eqmi.WDS.process_qmux_sdu(Eqmi.WDS.qmux_sdu(:indication, 1, [ind]), hdr).messages
  end

  test "an id without a spec entry has no name" do
    msg = <<0xFF, 0x7F, 0::little-16>>
    assert [%{msg_id: 0x7FFF, name: nil, parameters: %{}}] = decode(Eqmi.NAS, :response, msg).messages
  end
end
