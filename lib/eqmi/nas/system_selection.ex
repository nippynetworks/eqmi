defmodule Eqmi.NAS.SystemSelection do
  @moduledoc """
  The modem's system selection preference as NAS reports and takes it
  (`Get System Selection Preference`, `Set System Selection Preference`):
  which radio technologies it may use, whether it may roam, and which
  LTE bands it may use. Names after libqmi's `QmiNasRatModePreference`
  and `QmiNasRoamingPreference`.

      {:ok, params} = Eqmi.query(dev, :qmi_nas, :get_system_selection_preference)
      Eqmi.NAS.SystemSelection.decode(params)
      #=> %{rats: [:gsm, :umts, :lte], roaming: :any, lte_bands: [1, 3, 7, 8, 20, ...],
      #     extended_bands?: true, network_selection: :automatic}

      Eqmi.query(dev, :qmi_nas, :set_system_selection_preference,
        mode_preference: Eqmi.NAS.SystemSelection.rat_mask([:lte]),
        change_duration: 1)
  """

  import Bitwise

  @rats [
    {1, :cdma_1x},
    {2, :cdma_1xevdo},
    {4, :gsm},
    {8, :umts},
    {16, :lte},
    {32, :td_scdma},
    {64, :nr5g}
  ]

  @roaming %{1 => :off, 2 => :not_off, 3 => :not_flashing, 255 => :any}

  @type rat :: :cdma_1x | :cdma_1xevdo | :gsm | :umts | :lte | :td_scdma | :nr5g
  @type roaming :: :off | :not_off | :not_flashing | :any

  @doc "The technologies in a mode preference mask."
  @spec rats(non_neg_integer()) :: [rat()]
  def rats(mask), do: for({bit, name} <- @rats, band(mask, bit) != 0, do: name)

  @doc "The mode preference mask for a list of technologies."
  @spec rat_mask([rat()]) :: non_neg_integer()
  def rat_mask(rats) do
    Enum.reduce(@rats, 0, fn {bit, name}, acc -> if name in rats, do: acc ||| bit, else: acc end)
  end

  @doc "Name of a roaming preference value."
  @spec roaming_preference(non_neg_integer()) :: roaming() | non_neg_integer()
  def roaming_preference(code), do: Map.get(@roaming, code, code)

  @doc "Value of a roaming preference name."
  @spec roaming_code(roaming()) :: non_neg_integer() | nil
  def roaming_code(name), do: Enum.find_value(@roaming, fn {c, n} -> if n == name, do: c end)

  @doc "The LTE bands in a 64-bit band preference mask (bit n-1 is band n)."
  @spec lte_bands(non_neg_integer()) :: [pos_integer()]
  def lte_bands(mask), do: bands_of(mask, 0)

  @doc "The 64-bit band preference mask for LTE bands 1 to 64 (higher bands are left out)."
  @spec lte_band_mask([pos_integer()]) :: non_neg_integer()
  def lte_band_mask(bands), do: mask_of(bands, 0)

  @doc """
  The LTE bands in an extended band preference (four 64-bit masks:
  bands 1-64, 65-128, 129-192, 193-256).
  """
  @spec extended_lte_bands(map()) :: [pos_integer()]
  def extended_lte_bands(%{} = seq) do
    bands_of(seq[:mask_low] || 0, 0) ++
      bands_of(seq[:mask_mid_low] || 0, 64) ++
      bands_of(seq[:mask_mid_high] || 0, 128) ++
      bands_of(seq[:mask_high] || 0, 192)
  end

  @doc "The extended band preference (as request parameters) for LTE bands 1 to 256."
  @spec extended_lte_band_mask([pos_integer()]) :: keyword()
  def extended_lte_band_mask(bands) do
    [
      mask_low: mask_of(bands, 0),
      mask_mid_low: mask_of(bands, 64),
      mask_mid_high: mask_of(bands, 128),
      mask_high: mask_of(bands, 192)
    ]
  end

  @doc """
  A `Get System Selection Preference` response as one map: `rats`,
  `roaming`, `lte_bands` (from the extended preference when the modem
  reports one, else the 64-bit one), `extended_bands?` and
  `network_selection` (`:automatic` or `:manual`); a field the modem
  did not report is nil.
  """
  @spec decode(map()) :: map()
  def decode(params) when is_map(params) do
    extended = params[:extended_lte_band_preference]

    %{
      rats: params[:mode_preference] && rats(params[:mode_preference]),
      roaming: params[:roaming_preference] && roaming_preference(params[:roaming_preference]),
      lte_bands:
        cond do
          is_map(extended) -> extended_lte_bands(extended)
          params[:lte_band_preference] -> lte_bands(params[:lte_band_preference])
          true -> nil
        end,
      extended_bands?: is_map(extended),
      network_selection:
        case params[:network_selection_preference] do
          0 -> :automatic
          1 -> :manual
          other -> other
        end
    }
  end

  defp bands_of(mask, offset) do
    for bit <- 0..63, band(mask, 1 <<< bit) != 0, do: bit + 1 + offset
  end

  defp mask_of(bands, offset) do
    Enum.reduce(bands, 0, fn band, acc ->
      bit = band - 1 - offset
      if bit >= 0 and bit < 64, do: acc ||| 1 <<< bit, else: acc
    end)
  end
end
