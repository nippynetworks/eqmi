defmodule EqmiErrorTest do
  use ExUnit.Case

  test "protocol error names" do
    assert Eqmi.Error.protocol(0) == :none
    assert Eqmi.Error.protocol(14) == :call_failed
    assert Eqmi.Error.protocol(15) == :out_of_call
    assert Eqmi.Error.protocol(61_441) == :cat_event_registration_failed
    assert Eqmi.Error.protocol(60_000) == 60_000
    assert Eqmi.Error.protocol_code(:out_of_call) == 15
  end

  test "WDS call end reasons" do
    assert Eqmi.Error.call_end_reason(1) == :generic_unspecified

    assert Eqmi.Error.verbose_call_end_reason(%{type: 2, reason: 241}) ==
             {:internal, :interface_in_use_config_match}

    assert Eqmi.Error.verbose_call_end_reason(2, 208) == {:internal, :pdn_ipv4_call_disallowed}
    assert Eqmi.Error.verbose_call_end_reason(2, 231) == {:internal, :ip_version_mismatch}
    assert Eqmi.Error.verbose_call_end_reason(6, 33) == {:"3gpp", :option_unsubscribed}
    assert Eqmi.Error.verbose_call_end_reason(99, 1) == {99, 1}
  end
end
