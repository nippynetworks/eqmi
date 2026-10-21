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

  test "WDS Get LTE Attach Parameters decodes the attach PDN IPv6 TLVs" do
    # captured from an EM12-G on an IPv6-only attach PDN
    tlvs =
      <<0x11, 1::little-16, 1, 0x16, 17::little-16, 42, 0, 35, 238, 40, 32, 7, 132, 46, 180, 168, 49, 51, 3,
        55, 217, 64, 0x17, 17::little-16, 254, 128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 64>>

    msg = <<0x85, 0, byte_size(tlvs)::little-16, tlvs::binary>>
    assert [%{parameters: params}] = decode(Eqmi.WDS, :response, msg, :qmi_wds).messages

    assert params.ip_support_type == 1
    assert params.lte_attach_ipv6_address == %{address: [0x2A00, 0x23EE, 0x2820, 0x0784, 0x2EB4, 0xA831, 0x3303, 0x37D9], prefix_length: 64}
    assert params.lte_attach_ipv6_link_local_address == %{address: [0xFE80, 0, 0, 0, 0, 0, 0, 1], prefix_length: 64}
    refute Map.has_key?(params, :unknown)
  end

  test "WDS Get LTE Attach Parameters decodes the attach PDN IPv4 address" do
    # captured from an EM12-G attached as IPv4: 100.69.195.81
    tlvs = <<0x11, 1::little-16, 0, 0x13, 4::little-16, 81, 195, 69, 100>>
    msg = <<0x85, 0, byte_size(tlvs)::little-16, tlvs::binary>>
    assert [%{parameters: %{ip_support_type: 0, lte_attach_ipv4_address: 0x6445C351} = params}] =
             decode(Eqmi.WDS, :response, msg, :qmi_wds).messages

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
