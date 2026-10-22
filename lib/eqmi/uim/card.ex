defmodule Eqmi.UIM.Card do
  @moduledoc """
  The SIM as the UIM service reports it: the `card_status` parameter of
  `Get Card Status` and of the `Card Status` indication reduced to the
  card and application the modem uses for 3GPP service, with named
  states and the PIN that applies.

      {:ok, %{card_status: status}} = Eqmi.query(dev, :qmi_uim, :get_card_status)
      Eqmi.UIM.Card.state(status)
      #=> %{state: :ready, card: :present,
      #     application: %{type: :usim, state: :ready},
      #     pin: %{id: :pin1, state: :disabled, retries: 3, unblock_retries: 10}}

  `state` is one of `:absent`, `:error` (with `card_error`), `:ready`,
  `:pin_required`, `:puk_required`, `:blocked` (the card is illegal) and
  `:unknown` (the application is still being detected). Names follow
  libqmi's `QmiUimCardState`, `QmiUimCardApplicationState`,
  `QmiUimPinState` and `QmiUimCardApplicationType`.
  """

  @type state :: :absent | :error | :ready | :pin_required | :puk_required | :blocked | :unknown

  @card_state %{0 => :absent, 1 => :present, 2 => :error}
  @pin_state %{
    0 => :not_initialized,
    1 => :enabled_not_verified,
    2 => :enabled_verified,
    3 => :disabled,
    4 => :blocked,
    5 => :permanently_blocked
  }
  @app_state %{
    0 => :unknown,
    1 => :detected,
    2 => :pin_required,
    3 => :puk_required,
    4 => :check_personalization,
    5 => :pin1_blocked,
    6 => :illegal,
    7 => :ready
  }
  @app_type %{0 => :unknown, 1 => :sim, 2 => :usim, 3 => :ruim, 4 => :csim, 5 => :isim}

  @doc """
  The card and the primary GW (3GPP) application from a `card_status`
  parameter, as one `state` with the PIN details a caller needs to act.
  """
  @spec state(map() | nil) :: %{
          state: state(),
          card: atom(),
          application: map() | nil,
          pin: map() | nil
        }
  def state(nil), do: %{state: :unknown, card: :unknown, application: nil, pin: nil}

  def state(%{cards: cards} = status) do
    {card_index, app_index} = split_index(status[:index_gw_primary])
    card = Enum.at(cards, card_index)
    app = card && Enum.at(card[:applications] || [], app_index)
    card_state = card && Map.get(@card_state, card[:card_state], :unknown)

    cond do
      card == nil or card_state == :absent ->
        %{state: :absent, card: card_state || :absent, application: nil, pin: nil}

      card_state == :error ->
        %{state: :error, card: :error, card_error: card[:error_code], application: nil, pin: nil}

      app == nil ->
        %{state: :unknown, card: :present, application: nil, pin: nil}

      true ->
        pin = pin_of(card, app)
        app_state = Map.get(@app_state, app[:state], :unknown)

        %{
          state: state_of(app_state),
          card: :present,
          application: %{type: Map.get(@app_type, app[:type], :unknown), state: app_state},
          pin: pin
        }
    end
  end

  def state(_other), do: %{state: :unknown, card: :unknown, application: nil, pin: nil}

  @doc "Name of a card state value."
  def card_state(code), do: Map.get(@card_state, code, code)

  @doc "Name of an application state value."
  def application_state(code), do: Map.get(@app_state, code, code)

  @doc "Name of an application type value."
  def application_type(code), do: Map.get(@app_type, code, code)

  @doc "Name of a PIN state value."
  def pin_state(code), do: Map.get(@pin_state, code, code)

  defp state_of(:ready), do: :ready
  defp state_of(:pin_required), do: :pin_required
  defp state_of(:puk_required), do: :puk_required
  defp state_of(:pin1_blocked), do: :puk_required
  defp state_of(:illegal), do: :blocked
  defp state_of(_detected_or_unknown), do: :unknown

  # the PIN that applies: the UPIN when it replaces PIN1, else PIN1
  defp pin_of(card, app) do
    if app[:upin_replaces_pin1] == 1 do
      %{
        id: :upin,
        state: Map.get(@pin_state, card[:upin_state]),
        retries: card[:upin_retries],
        unblock_retries: card[:upuk_retries]
      }
    else
      %{
        id: :pin1,
        state: Map.get(@pin_state, app[:pin1_state]),
        retries: app[:pin1_retries],
        unblock_retries: app[:puk1_retries]
      }
    end
  end

  # card index in the high byte, application index in the low; 0xFFFF = none
  defp split_index(nil), do: {0, 0}
  defp split_index(0xFFFF), do: {0, 0}
  defp split_index(index), do: {div(index, 256), rem(index, 256)}
end
