defmodule Eqmi.Builder.Utils do
  # ids are written as "0x..." hex of any length and case ("0x1", "0x000e")
  def id_from_str("0x" <> hex), do: String.to_integer(hex, 16)
  def id_from_str("0X" <> hex), do: String.to_integer(hex, 16)

  def replace_common(elements, common_def) do
    elements
    |> Enum.map(fn x ->
      if Map.has_key?(x, "input") do
        %{x | "input" => replace_list(x["input"], common_def)}
      else
        x
      end
    end)
    |> Enum.map(fn x ->
      if Map.has_key?(x, "output") do
        %{x | "output" => replace_list(x["output"], common_def)}
      else
        x
      end
    end)
    |> Enum.map(fn x ->
      if Map.has_key?(x, "indication") do
        %{x | "indication" => replace_list(x["indication"], common_def)}
      else
        x
      end
    end)
  end

  # A use site may carry its own "id", "name" or "since" on top of the shared
  # definition (newer libqmi data defines some common TLVs without an id and
  # assigns one per message), so the two are merged with the use site winning.
  defp replace_list(content, common_def) do
    content
    |> Enum.map(fn
      %{"common-ref" => ref} = x when is_map_key(common_def, ref) ->
        Map.merge(common_def[ref], Map.delete(x, "common-ref"))

      x ->
        x
    end)
  end

  def transform_name(content) do
    transform_name_list(content, [])
  end

  defp transform_name_list([], acc) do
    acc
    |> Enum.reverse()
  end

  defp transform_name_list([h | t], acc) do
    new_obj = rename_obj(h)
    transform_name_list(t, [new_obj | acc])
  end

  defp rename_obj(%{"format" => "sequence"} = obj) do
    name = name_to_atom(obj["name"])
    %{obj | "name" => name, "contents" => transform_name_list(obj["contents"], [])}
  end

  defp rename_obj(%{"format" => "struct"} = obj) do
    name = name_to_atom(obj["name"])

    %{obj | "name" => name, "contents" => transform_name_list(obj["contents"], [])}
  end

  defp rename_obj(%{"format" => "array"} = obj) do
    name = name_to_atom(obj["name"])

    %{obj | "name" => name, "array-element" => rename_obj(obj["array-element"])}
  end

  defp rename_obj(%{"name" => name} = obj) do
    n = name_to_atom(name)

    %{obj | "name" => n}
  end

  defp rename_obj(obj) do
    obj
  end

  def name_to_atom(name) do
    name |> String.replace(" ", "_") |> String.downcase() |> String.to_atom()
  end
end
