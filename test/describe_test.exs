defmodule EqmiDescribeTest do
  use ExUnit.Case

  test "describe/2 lists a message's parameters from the spec" do
    d = Eqmi.describe(:qmi_nas, :get_signal_strength)
    assert d.id == 0x20 and d.type == :message
    assert d.input == [%{name: :request_mask, id: 0x10, format: "guint16"}]
    assert Enum.find(d.output, &(&1.name == :lte_rsrp)) == %{name: :lte_rsrp, id: 0x18, format: "gint16"}

    signal = Eqmi.describe(:qmi_nas, :get_signal_info)
    lte = Enum.find(signal.output, &(&1.name == :lte_signal_strength))
    assert lte.format == "sequence"
    assert Enum.map(lte.fields, & &1.name) == [:rssi, :rsrq, :rsrp, :snr]

    ind = Eqmi.describe(:qmi_wds, :packet_service_status)
    assert ind.type == :indication and ind.id == 0x22
    assert Enum.find(ind.output, &(&1.name == :tech_name))

    assert Eqmi.describe(:qmi_nas, :no_such_message) == nil
    assert Eqmi.describe(:qmi_nope, :get_signal_info) == nil
  end

  test "messages/1 enumerates a service" do
    names = Eqmi.messages(:qmi_dms) |> Enum.map(& &1.name)
    assert :get_model in names and :get_revision in names
  end

  test "query defaults cover the selector inputs only" do
    assert Eqmi.query_defaults(:qmi_nas, :get_signal_strength) == [request_mask: 0xFF]
    assert Eqmi.query_defaults(:qmi_wds, :get_current_settings) == [requested_settings: 0xFFFFFFFF]
    assert Eqmi.query_defaults(:qmi_nas, :get_signal_info) == []
    # a caller's own value wins
    assert Keyword.merge(Eqmi.query_defaults(:qmi_nas, :get_signal_strength), request_mask: 1) == [request_mask: 1]
  end
end
