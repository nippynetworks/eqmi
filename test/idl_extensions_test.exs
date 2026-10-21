defmodule EqmiIdlExtensionsTest do
  use ExUnit.Case

  # TLVs corrected or added from the Qualcomm QMI IDL headers where libqmi's
  # data is wrong or silent (see tools/idl_compare.py)
  @ok [error_status: 0, error_code: 0]

  defp decode(mod, type, msg, service) do
    hdr = %{service_type: service, client_id: 1, sender_type: :service}
    mod.process_qmux_sdu(mod.qmux_sdu(type, 1, [msg]), hdr)
  end

  test "NAS Set Event Report encodes the LTE SNR delta as 16 bits" do
    # report (u8) + delta in 0.1 dB (u16): a 3-byte TLV (libqmi's guint8 made it 2)
    assert Eqmi.NAS.request(:set_event_report, lte_snr_delta: [report: 1, snr_delta: 30]) ==
             <<0x02, 0, 6::little-16, 0x1B, 3::little-16, 1, 30::little-16>>
  end

  test "WDS Packet Service Status indication carries the technology name" do
    tlvs = <<0x01, 2::little-16, 2, 0, 0x13, 2::little-16, 0x8880::little-16>>
    msg = <<0x22, 0, byte_size(tlvs)::little-16, tlvs::binary>>

    assert [%{name: :packet_service_status, parameters: params}] =
             decode(Eqmi.WDS, :indication, msg, :qmi_wds).messages

    assert params.tech_name == 0x8880
    assert params.connection_status == %{status: 2, reconfiguration_required: 0}
    refute Map.has_key?(params, :unknown)
  end

  test "DMS Get MSISDN decodes the mobile id number and IMSI" do
    msg = Eqmi.DMS.response(:get_msisdn, msisdn: "447700900123", mobile_id_number: "0000000000", imsi: "234300000000001", result: @ok)
    assert [%{parameters: %{msisdn: "447700900123", imsi: "234300000000001", mobile_id_number: "0000000000"}}] =
             decode(Eqmi.DMS, :response, msg, :qmi_dms).messages
  end

  test "DMS Get Revision decodes the boot code and PRI revisions" do
    msg = Eqmi.DMS.response(:get_revision, revision: "EM12GPAR01A21M4G", boot_code_revision: "SBL1", pri_revision: "01.001", result: @ok)
    assert [%{parameters: %{revision: "EM12GPAR01A21M4G", boot_code_revision: "SBL1", pri_revision: "01.001"}}] =
             decode(Eqmi.DMS, :response, msg, :qmi_dms).messages
  end
end
