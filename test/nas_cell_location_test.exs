defmodule EqmiNasCellLocationTest do
  use ExUnit.Case

  @hdr %{service_type: :qmi_nas, client_id: 5, sender_type: :service}

  # a Get Cell Location Info response captured from a modem on LTE; it ends
  # with TLVs 0x26, 0x27 and 0x28, which libqmi does not define
  @captured <<2, 1, 0, 67, 0, 190, 0, 2, 4, 0, 0, 0, 0, 0, 19, 29, 0, 1, 55, 240, 32, 50, 5, 34, 94,
              17, 0, 228, 12, 11, 0, 7, 6, 4, 56, 1, 11, 0, 116, 255, 177, 251, 4, 253, 15, 0, 20,
              14, 0, 1, 2, 232, 3, 0, 8, 4, 0, 144, 36, 0, 8, 3, 0, 21, 79, 0, 1, 1, 0, 0, 6, 255,
              8, 0, 0, 1, 0, 0, 128, 248, 0, 0, 175, 2, 1, 0, 0, 128, 248, 0, 0, 176, 2, 1, 0, 0,
              128, 248, 0, 0, 177, 2, 1, 0, 0, 128, 248, 0, 0, 178, 2, 1, 0, 0, 128, 248, 0, 0,
              179, 2, 1, 0, 0, 128, 248, 0, 0, 180, 2, 1, 0, 0, 128, 248, 0, 0, 181, 2, 1, 0, 0,
              128, 248, 0, 0, 22, 18, 0, 1, 2, 6, 17, 2, 0, 0, 0, 0, 0, 31, 17, 2, 0, 0, 0, 0, 0,
              30, 4, 0, 255, 255, 255, 255, 38, 2, 0, 70, 0, 39, 4, 0, 228, 12, 0, 0, 40, 9, 0, 2,
              232, 3, 0, 0, 144, 36, 0, 0>>

  test "doppler and extended EARFCN TLVs decode by name" do
    assert [%{name: :get_cell_location_info, parameters: p}] =
             Eqmi.NAS.process_qmux_sdu(@captured, @hdr).messages

    assert p.doppler_measurement == 70
    assert p.lte_info_intrafrequency_earfcn == 3300
    assert p.lte_info_interfrequency_earfcn == [1000, 9360]
    assert p.lte_info_timing_advance == 0xFFFFFFFF
    # the 32-bit EARFCNs repeat the 16-bit ones in the LTE info TLVs
    assert p.intrafrequency_lte_info_v2.eutra_absolute_rf_channel_number == 3300
    assert Enum.map(p.interfrequency_lte_info.frequency, & &1.eutra_absolute_rf_channel_number) == [1000, 9360]
    refute Map.has_key?(p, :unknown)
  end

  test "EMM and RRC state TLVs decode by name" do
    # values seen on an EM12-G: registered (3), RRC idle (0)
    tlvs = <<0x2A, 4::little-16, 3::little-32, 0x2C, 4::little-16, 0::little-32>>
    msg = <<0x43, 0, byte_size(tlvs)::little-16, tlvs::binary>>

    assert [%{parameters: %{lte_info_emm_state: 3, lte_info_rrc_state: 0}}] =
             Eqmi.NAS.process_qmux_sdu(Eqmi.NAS.qmux_sdu(:response, 1, [msg]), @hdr).messages
  end
end
