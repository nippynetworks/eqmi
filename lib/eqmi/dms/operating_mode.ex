defmodule Eqmi.DMS.OperatingMode do
  @moduledoc """
  The modem's operating mode as DMS reports it (`Get Operating Mode`,
  `Set Operating Mode`), with names after libqmi's `QmiDmsOperatingMode`
  and `QmiDmsOfflineReason`.

      {:ok, params} = Eqmi.query(dev, :qmi_dms, :get_operating_mode)
      Eqmi.DMS.OperatingMode.decode(params)
      #=> %{mode: :online, offline_reasons: [], hardware_restricted?: false}

  A modem that is not `:online` does not register or carry data. The
  low-power modes and `:offline` can be left with `Set Operating Mode`
  (`mode: Eqmi.DMS.OperatingMode.code(:online)`); `:persistent_low_power`
  and a hardware-restricted mode cannot.
  """

  @modes %{
    0 => :online,
    1 => :low_power,
    2 => :factory_test,
    3 => :offline,
    4 => :reset,
    5 => :shutting_down,
    6 => :persistent_low_power,
    7 => :mode_only_low_power,
    255 => :unknown
  }

  @offline_reasons [
    {1, :host_image_misconfiguration},
    {2, :pri_image_misconfiguration},
    {4, :pri_version_incompatible},
    {8, :device_memory_full}
  ]

  @type mode ::
          :online
          | :low_power
          | :persistent_low_power
          | :factory_test
          | :offline
          | :reset
          | :shutting_down
          | :mode_only_low_power
          | :unknown
          | non_neg_integer()

  @doc "Name of an operating mode value, or the value when unknown."
  @spec name(non_neg_integer()) :: mode()
  def name(code), do: Map.get(@modes, code, code)

  @doc "Value of an operating mode name."
  @spec code(atom()) :: non_neg_integer() | nil
  def code(name), do: Enum.find_value(@modes, fn {c, n} -> if n == name, do: c end)

  @doc "Names of the offline reason flags set in a value."
  @spec offline_reasons(non_neg_integer() | nil) :: [atom()]
  def offline_reasons(nil), do: []

  def offline_reasons(flags) do
    for {bit, name} <- @offline_reasons, Bitwise.band(flags, bit) != 0, do: name
  end

  @doc """
  The `Get Operating Mode` response as one map: `mode`, `offline_reasons`
  and `hardware_restricted?`.
  """
  @spec decode(map()) :: %{
          mode: mode(),
          offline_reasons: [atom()],
          hardware_restricted?: boolean()
        }
  def decode(params) when is_map(params) do
    %{
      mode: name(params[:mode]),
      offline_reasons: offline_reasons(params[:offline_reason]),
      hardware_restricted?: params[:hardware_restricted_mode] == 1
    }
  end

  @doc "Can `Set Operating Mode` bring a modem in this mode online?"
  @spec settable?(%{mode: mode(), hardware_restricted?: boolean()}) :: boolean()
  def settable?(%{hardware_restricted?: true}), do: false
  def settable?(%{mode: mode}), do: mode in [:low_power, :offline, :mode_only_low_power]
end
