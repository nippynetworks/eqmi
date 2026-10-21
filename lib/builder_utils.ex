defmodule Eqmi.Builder.Utils do
  @doc "Read a libqmi spec file: drop the // comment lines and decode the JSON."
  def read_spec(path) do
    path
    |> File.stream!()
    |> Stream.reject(fn line -> line |> String.trim() |> String.starts_with?("//") end)
    |> Enum.join()
    |> Jason.decode!()
  end

  @doc """
  Load a service spec file: returns `{service_name, messages}` where messages
  are the "Message" and "Indication" entries with every common-ref resolved
  and an indication's "output" renamed to "indication".

  Entries are selected by their "type" rather than by position: the files
  start with Service / Client / Message-ID-Enum / Indication-ID-Enum headers,
  but services without indications omit the last one, and some files put a
  common TLV definition first.
  """
  def load_service(path, common_base) do
    svc_data = read_spec(path)
    module = Enum.find(svc_data, fn x -> x["type"] == "Service" end)

    common_defs =
      svc_data
      |> Enum.filter(fn x -> Map.has_key?(x, "common-ref") end)
      |> Enum.concat(common_base)
      |> Enum.reduce(%{}, fn x, acc ->
        Map.put(acc, x["common-ref"], Map.delete(x, "common-ref"))
      end)

    indications =
      svc_data
      |> Enum.filter(fn e -> e["type"] == "Indication" end)
      |> Enum.map(fn e ->
        case Map.pop(e, "output") do
          {nil, m} -> m
          {v, m} -> Map.put(m, "indication", v)
        end
      end)

    messages =
      svc_data
      |> Enum.filter(fn e -> e["type"] == "Message" end)
      |> Enum.concat(indications)
      |> replace_common(common_defs)

    {module["name"], messages}
  end

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

  @doc """
  Return a compact, data-only description of a message: its name, id, type and
  the TLVs it takes (`:input`) and returns (`:output`), each with the atom
  the decoder uses, the TLV id, the format and nested fields.
  """
  def describe_message(command) do
    %{
      name: name_to_atom(command["name"]),
      id: id_from_str(command["id"]),
      type: if(command["type"] == "Indication", do: :indication, else: :message),
      input: Enum.map(command["input"] || [], &describe_tlv/1),
      output: Enum.map(command["output"] || command["indication"] || [], &describe_tlv/1)
    }
  end

  defp describe_tlv(%{"format" => format} = t) do
    # array elements of a plain type carry no name
    base = %{name: name_to_atom(t["name"] || "element"), format: format}
    base = if t["id"], do: Map.put(base, :id, id_from_str(t["id"])), else: base

    case format do
      f when f in ["sequence", "struct"] ->
        Map.put(base, :fields, Enum.map(t["contents"], &describe_tlv/1))

      "array" ->
        base
        |> Map.put(:element, describe_tlv(t["array-element"]))
        |> Map.put(:size, t["fixed-size"] || t["size-prefix-format"] || "guint8")

      "string" ->
        if t["fixed-size"], do: Map.put(base, :size, t["fixed-size"]), else: base

      _ ->
        base
    end
  end

  defp describe_tlv(t), do: %{name: name_to_atom(t["name"] || "element"), format: t["format"]}

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
