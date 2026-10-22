defmodule EqmiUimCardTest do
  use ExUnit.Case, async: true
  alias Eqmi.UIM.Card

  # a ready USIM with PIN1 disabled, as Get Card Status reports it
  defp card_status(app_overrides \\ %{}, card_overrides \\ %{}) do
    app =
      Map.merge(
        %{
          type: 2,
          state: 7,
          personalization_state: 0,
          personalization_feature: 0,
          pin1_state: 3,
          pin1_retries: 3,
          puk1_retries: 10,
          pin2_state: 3,
          pin2_retries: 3,
          puk2_retries: 10,
          upin_replaces_pin1: 0,
          application_identifier_value: [0xA0, 0, 0, 0, 0x87]
        },
        app_overrides
      )

    card =
      Map.merge(
        %{
          card_state: 1,
          upin_state: 0,
          upin_retries: 0,
          upuk_retries: 0,
          error_code: 0,
          applications: [app]
        },
        card_overrides
      )

    %{
      index_gw_primary: 0x0000,
      index_1x_primary: 0xFFFF,
      index_gw_secondary: 0xFFFF,
      index_1x_secondary: 0xFFFF,
      cards: [card]
    }
  end

  test "a ready USIM" do
    assert %{state: :ready, card: :present, application: %{type: :usim, state: :ready}, pin: pin} =
             Card.state(card_status())

    assert pin == %{id: :pin1, state: :disabled, retries: 3, unblock_retries: 10}
  end

  test "PIN and PUK required, blocked, absent, error" do
    assert %{state: :pin_required, pin: %{state: :enabled_not_verified, retries: 2}} =
             Card.state(card_status(%{state: 2, pin1_state: 1, pin1_retries: 2}))

    assert %{state: :puk_required} = Card.state(card_status(%{state: 3, pin1_state: 4}))
    assert %{state: :puk_required} = Card.state(card_status(%{state: 5}))
    assert %{state: :blocked} = Card.state(card_status(%{state: 6}))

    assert %{state: :absent, card: :absent} =
             Card.state(card_status(%{}, %{card_state: 0, applications: []}))

    assert %{state: :error, card_error: 3} =
             Card.state(card_status(%{}, %{card_state: 2, error_code: 3}))

    assert %{state: :unknown} = Card.state(nil)
  end

  test "the UPIN replaces PIN1 when the card says so" do
    status =
      card_status(%{upin_replaces_pin1: 1, state: 2}, %{
        upin_state: 1,
        upin_retries: 1,
        upuk_retries: 9
      })

    assert %{
             state: :pin_required,
             pin: %{id: :upin, state: :enabled_not_verified, retries: 1, unblock_retries: 9}
           } = Card.state(status)
  end

  test "the primary GW application index selects the card and application" do
    other = %{
      type: 5,
      state: 7,
      pin1_state: 3,
      pin1_retries: 3,
      puk1_retries: 10,
      upin_replaces_pin1: 0
    }

    status = card_status()
    [card] = status.cards

    status = %{
      status
      | cards: [%{card | applications: [other | card.applications]}],
        index_gw_primary: 0x0001
    }

    assert %{application: %{type: :usim}} = Card.state(status)
  end

  test "value names" do
    assert Card.card_state(2) == :error
    assert Card.application_state(7) == :ready
    assert Card.application_type(5) == :isim
    assert Card.pin_state(4) == :blocked
    assert Card.pin_state(99) == 99
  end
end
