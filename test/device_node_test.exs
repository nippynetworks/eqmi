defmodule EqmiDeviceNodeTest do
  use ExUnit.Case

  # Opening a missing path for writing would create a regular file where the
  # device node belongs; the Device must refuse anything but a character device.
  test "a missing path is reported, not created" do
    path = Path.join(System.tmp_dir!(), "eqmi-missing-#{System.unique_integer([:positive])}")
    assert {:error, :enoent} = Eqmi.device(path)
    refute File.exists?(path)
  end

  test "a regular file in place of the node is refused" do
    path = Path.join(System.tmp_dir!(), "eqmi-file-#{System.unique_integer([:positive])}")
    File.write!(path, "")
    assert {:error, {:not_a_device, :regular}} = Eqmi.device(path)
    File.rm!(path)
  end
end
