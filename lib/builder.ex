defmodule Eqmi.Builder do
  alias Eqmi.Types

  common_base = Eqmi.Builder.Utils.read_spec("priv/qmi-common.json")

  {:ok, flist} = File.ls("priv")

  svc_list =
    flist
    |> Enum.filter(fn x -> String.contains?(x, "service") end)
    |> Enum.map(fn x -> Path.join("priv", x) end)

  # the generated modules are compiled from these files, so a change to one
  # of them must recompile this file
  for f <- ["priv/qmi-common.json" | svc_list] do
    Module.put_attribute(__MODULE__, :external_resource, f)
  end

  for svc_file_name <- svc_list do
    {service_name, ctl_msgs} = Eqmi.Builder.Utils.load_service(svc_file_name, common_base)

    tx_bits = if service_name == "CTL", do: 1, else: 2
    type_shift = if service_name == "CTL", do: 1, else: 0

    decoder_generator = [
      {"decode_request_tlv", "input"},
      {"decode_response_tlv", "output"},
      {"decode_indication_tlv", "indication"}
    ]

    # One decoder clause per (direction, message id, TLV id). Vendor messages
    # that reuse a message id (DMS 0x5556, 0x5571) would otherwise produce
    # duplicate clauses; the first definition wins.
    decoder_clauses =
      for command <- ctl_msgs,
          {fun, direction} <- decoder_generator,
          params <- Map.get(command, direction, []) |> Eqmi.Builder.Utils.transform_name() do
        {fun, Eqmi.Builder.Utils.id_from_str(command["id"]),
         Eqmi.Builder.Utils.id_from_str(params["id"]), params}
      end
      |> Enum.uniq_by(fn {fun, msg_id, param_id, _params} -> {fun, msg_id, param_id} end)

    encoder_generator = [
      {"request", "input"},
      {"response", "output"}
    ]

    defmodule Module.concat(Eqmi, service_name) do
      require Eqmi.Builder.Decoder
      require Eqmi.Builder.Encoder
      require Logger

      def process_qmux_sdu(msg, payload) do
        <<m_type::binary-size(1), tx_id::binary-size(unquote(tx_bits)), rest::binary>> = msg

        msg_type =
          m_type
          |> :binary.decode_unsigned(:little)
          |> Bitwise.<<<(unquote(type_shift))
          |> Types.get_message_atom()

        decode_func = get_decode_func(msg_type)
        messages = process_messages(rest, msg_type, decode_func, [])

        payload
        |> Map.put(
          :message_type,
          msg_type
        )
        |> Map.put(:tx_id, tx_id |> :binary.decode_unsigned(:little))
        |> Map.put(:messages, messages)
      end

      def qmux_sdu(msg_type, transaction_id, messages) do
        msg_id = Eqmi.message_type_id(msg_type)

        ctrl_flag = <<msg_id::unsigned-integer-size(8)>>
        tx_bits_number = unquote(tx_bits) * 8
        tx_id = <<transaction_id::little-unsigned-integer-size(tx_bits_number)>>

        [ctrl_flag, tx_id, messages]
        |> :erlang.list_to_binary()
      end

      defp process_messages(<<>>, _, _, msgs) do
        msgs
      end

      defp process_messages(content, msg_type, decode_func, msgs) do
        <<msg_id::little-unsigned-integer-size(16), len::little-unsigned-integer-size(16),
          rest::binary>> = content

        <<tlv_bin::binary-size(^len), rem_msgs::binary>> = rest
        params = decode_tlvs(tlv_bin, msg_id, decode_func, %{})

        message = %{
          msg_id: msg_id,
          name: message_name(msg_type, msg_id),
          parameters: params
        }

        process_messages(rem_msgs, msg_type, decode_func, [message | msgs])
      end

      # Each TLV decodes to `{name, value}`, or `{:unknown, id, raw}` when the
      # spec has no entry for it in this message. The message's parameters are
      # one map keyed by TLV name; unknown TLVs are kept under `:unknown` by id.
      defp decode_tlvs(<<>>, _, _, params) do
        params
      end

      defp decode_tlvs(content, msg_id, decode_func, params) do
        <<id::unsigned-integer-size(8), tlv_len::little-unsigned-integer-size(16),
          buffer::binary>> = content

        <<tlv_content::binary-size(^tlv_len), rest::binary>> = buffer
        params = put_param(params, decode_tlv(decode_func, msg_id, id, tlv_content))
        decode_tlvs(rest, msg_id, decode_func, params)
      end

      # A TLV whose payload does not fit its spec entry (firmware quirk or a
      # spec mistake) is kept raw rather than failing the whole message.
      defp decode_tlv(decode_func, msg_id, id, content) do
        decode_func.(msg_id, id, content)
      rescue
        e ->
          Logger.warning(
            "#{inspect(__MODULE__)}: cannot decode TLV #{id} of message #{msg_id} " <>
              "(#{Exception.message(e)}); keeping raw bytes"
          )

          {:unknown, id, content}
      end

      defp put_param(params, {:unknown, id, raw}) do
        Map.update(params, :unknown, %{id => raw}, &Map.put(&1, id, raw))
      end

      defp put_param(params, {name, value}) do
        Map.put(params, name, value)
      end

      defp get_decode_func(:response) do
        &decode_response_tlv/3
      end

      defp get_decode_func(:request) do
        &decode_request_tlv/3
      end

      defp get_decode_func(:indication) do
        &decode_indication_tlv/3
      end

      for {fun, msg_id, param_id, params} <- decoder_clauses do
        defp unquote(:"#{fun}")(unquote(msg_id), unquote(param_id), msg) do
          if false do
            msg
          else
            Eqmi.Builder.Decoder.create(unquote(params))
          end
        end
      end

      for command <- ctl_msgs do
        msg_id =
          command["id"]
          |> Eqmi.Builder.Utils.id_from_str()

        if command["type"] == "Indication" do
          elements =
            Map.get(command, "indication", [])
            |> Eqmi.Builder.Utils.transform_name()

          msg_name = Eqmi.Builder.Utils.name_to_atom(command["name"])

          def message_name(:indication, unquote(msg_id)), do: unquote(msg_name)

          def indication(
                unquote(msg_name),
                params
              ) do
            if false do
              params
            else
              Eqmi.Builder.Encoder.create(unquote(elements), unquote(msg_id))
            end
          end
        else
          msg_name = Eqmi.Builder.Utils.name_to_atom(command["name"])

          def message_name(type, unquote(msg_id)) when type in [:request, :response],
            do: unquote(msg_name)

          for {fun, direction} <- encoder_generator do
            elements =
              Map.get(command, direction, [])
              |> Eqmi.Builder.Utils.transform_name()

            def unquote(:"#{fun}")(
                  unquote(msg_name),
                  params
                ) do
              if false do
                params
              else
                Eqmi.Builder.Encoder.create(unquote(elements), unquote(msg_id))
              end
            end
          end
        end
      end

      @doc "Spec name of a message id for a direction, or nil if unknown."
      def message_name(_type, _msg_id), do: nil

      defp decode_request_tlv(_, id, value), do: {:unknown, id, value}
      defp decode_response_tlv(_, id, value), do: {:unknown, id, value}
      defp decode_indication_tlv(_, id, value), do: {:unknown, id, value}
    end
  end
end
