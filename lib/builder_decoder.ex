defmodule Eqmi.Builder.Decoder do
  # Decodes one TLV value according to its spec entry and returns it as a
  # `{name, value}` pair for the message's parameter map.
  defmacro create(payload) do
    quote do
      {res, _} =
        unquote(Macro.escape(payload))
        |> Eqmi.Tlv.decode_tlv(var!(msg))

      {unquote(payload["name"]), res}
    end
  end
end
