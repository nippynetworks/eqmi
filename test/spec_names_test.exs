defmodule EqmiSpecNamesTest do
  use ExUnit.Case

  alias Eqmi.Builder.Utils

  @moduledoc """
  Decoded parameters are maps keyed by the atom made from each TLV's name,
  and sequences, structs and array elements decode the same way one level
  down. A duplicate name inside one definition would therefore overwrite a
  value silently, and a TLV named "Unknown" would collide with the key the
  decoder uses for TLVs it cannot decode. These checks run over every spec
  file exactly as the builder loads it.
  """

  @common Utils.read_spec("priv/qmi-common.json")
  @services Path.wildcard("priv/qmi-service-*.json")

  for path <- @services do
    test "#{Path.basename(path)}: no duplicate names inside one definition" do
      {service, messages} = Utils.load_service(unquote(path), @common)

      for message <- messages,
          {direction, tlvs} <- Map.take(message, ["input", "output", "indication"]) do
        where = "#{service} #{message["type"]} #{message["id"]} #{message["name"]} #{direction}"
        names = Enum.map(tlvs, &Utils.name_to_atom(&1["name"]))
        assert_unique(names, where)
        refute :unknown in names, "#{where}: a TLV named Unknown collides with the :unknown key"
        Enum.each(tlvs, &assert_unique_fields(&1, where <> " / " <> &1["name"]))
      end
    end

    test "#{Path.basename(path)}: message names are unique per direction" do
      {service, messages} = Utils.load_service(unquote(path), @common)

      for {type, group} <- Enum.group_by(messages, & &1["type"]) do
        assert_unique(Enum.map(group, &Utils.name_to_atom(&1["name"])), "#{service} #{type} names")
      end
    end
  end

  # sequences, structs and array elements carry their own field names
  defp assert_unique_fields(%{"contents" => contents} = def, where) do
    assert_unique(Enum.map(contents, &Utils.name_to_atom(&1["name"])), where)
    Enum.each(contents, &assert_unique_fields(&1, where <> " / " <> &1["name"]))
    assert_unique_fields(Map.delete(def, "contents"), where)
  end

  defp assert_unique_fields(%{"array-element" => element}, where) do
    assert_unique_fields(element, where <> " []")
  end

  defp assert_unique_fields(_leaf, _where), do: :ok

  defp assert_unique(names, where) do
    dups = names -- Enum.uniq(names)
    assert dups == [], "#{where}: duplicate names #{inspect(Enum.uniq(dups))}"
  end
end
