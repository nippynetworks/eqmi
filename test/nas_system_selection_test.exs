defmodule EqmiNasSystemSelectionTest do
  use ExUnit.Case, async: true
  import Bitwise
  alias Eqmi.NAS.SystemSelection, as: Sel

  test "technologies and masks" do
    assert Sel.rats(0x1C) == [:gsm, :umts, :lte]
    assert Sel.rats(0) == []
    assert Sel.rat_mask([:lte]) == 16
    assert Sel.rat_mask([:lte, :nr5g, :gsm]) == 84
    assert Sel.rats(Sel.rat_mask([:umts, :lte])) == [:umts, :lte]
  end

  test "roaming preference names" do
    assert Sel.roaming_preference(1) == :off
    assert Sel.roaming_preference(255) == :any
    assert Sel.roaming_preference(9) == 9
    assert Sel.roaming_code(:not_off) == 2
    assert Sel.roaming_code(:any) == 255
  end

  test "LTE bands and masks, plain and extended" do
    assert Sel.lte_bands(0b1000101) == [1, 3, 7]
    assert Sel.lte_band_mask([1, 3, 7, 66]) == 0b1000101
    assert Sel.lte_bands(1 <<< 63) == [64]

    ext = %{mask_low: 0b101, mask_mid_low: 0b10, mask_mid_high: 0, mask_high: 1 <<< 63}
    assert Sel.extended_lte_bands(ext) == [1, 3, 66, 256]

    assert Sel.extended_lte_band_mask([1, 3, 66, 256]) == [
             mask_low: 0b101,
             mask_mid_low: 0b10,
             mask_mid_high: 0,
             mask_high: 1 <<< 63
           ]
  end

  test "a response decodes" do
    assert Sel.decode(%{
             mode_preference: 0x18,
             roaming_preference: 255,
             lte_band_preference: 0b1000101,
             network_selection_preference: 0
           }) == %{
             rats: [:umts, :lte],
             roaming: :any,
             lte_bands: [1, 3, 7],
             extended_bands?: false,
             network_selection: :automatic
           }

    assert %{lte_bands: [1, 66], extended_bands?: true, rats: nil, roaming: nil} =
             Sel.decode(%{
               lte_band_preference: 1,
               extended_lte_band_preference: %{
                 mask_low: 1,
                 mask_mid_low: 2,
                 mask_mid_high: 0,
                 mask_high: 0
               }
             })
  end
end
