defmodule EqmiDmsOperatingModeTest do
  use ExUnit.Case, async: true
  alias Eqmi.DMS.OperatingMode

  test "names and codes" do
    assert OperatingMode.name(0) == :online
    assert OperatingMode.name(1) == :low_power
    assert OperatingMode.name(3) == :offline
    assert OperatingMode.name(255) == :unknown
    assert OperatingMode.name(42) == 42
    assert OperatingMode.code(:online) == 0
    assert OperatingMode.code(:persistent_low_power) == 6
  end

  test "a response decodes, with offline reasons as names" do
    assert OperatingMode.decode(%{mode: 0}) ==
             %{mode: :online, offline_reasons: [], hardware_restricted?: false}

    assert OperatingMode.decode(%{mode: 3, offline_reason: 0b1001, hardware_restricted_mode: 1}) ==
             %{
               mode: :offline,
               offline_reasons: [:host_image_misconfiguration, :device_memory_full],
               hardware_restricted?: true
             }
  end

  test "which modes can be left for online" do
    assert OperatingMode.settable?(%{mode: :low_power, hardware_restricted?: false})
    assert OperatingMode.settable?(%{mode: :offline, hardware_restricted?: false})
    refute OperatingMode.settable?(%{mode: :persistent_low_power, hardware_restricted?: false})
    refute OperatingMode.settable?(%{mode: :low_power, hardware_restricted?: true})
    refute OperatingMode.settable?(%{mode: :online, hardware_restricted?: false})
  end
end
