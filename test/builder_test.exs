defmodule EqmiBuilderTest do
  use ExUnit.Case

  # Services without indications have no Indication-ID-Enum header entry.
  # Selecting spec entries by position used to drop their first message.
  test "first message of a service without indications is generated" do
    assert Eqmi.WDA.request(:get_supported_messages, []) == <<0x1E, 0, 0, 0>>
    assert Eqmi.DPM.request(:open_port, []) == <<0x20, 0, 0, 0>>
    assert Eqmi.PBM.request(:indication_register, []) == <<0x01, 0, 0, 0>>
  end

  test "messages of services with indications are still generated" do
    assert Eqmi.NAS.request(:get_signal_info, []) == <<0x4F, 0, 0, 0>>
    assert Eqmi.WDS.request(:get_packet_service_status, []) == <<0x22, 0, 0, 0>>
  end
end
