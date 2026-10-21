# tests tagged :device talk to a simulated QMI device and need QMI_DEVICE
# and SIM_DEVICE to be set
device_tests =
  if System.get_env("QMI_DEVICE") && System.get_env("SIM_DEVICE"), do: [], else: [:device]

ExUnit.start(exclude: [:skip | device_tests])
