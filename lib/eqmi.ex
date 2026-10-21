defmodule Eqmi do
  use GenServer
  require Logger

  @moduledoc """
  Documentation for `Eqmi`.
  """

  # Service and message-type id lookups live in Eqmi.Types (the single
  # source of truth used for both header encode/decode and CID allocation);
  # these delegate so callers keep a stable Eqmi.* API.
  defdelegate message_type_id(msg_name), to: Eqmi.Types, as: :message_id
  defdelegate service_type_id(msg_name), to: Eqmi.Types, as: :service_id

  def qmux_message(header, payload) do
    if_type = <<1::little-unsigned-integer-size(8)>>

    [if_type, header, payload]
    |> :erlang.list_to_binary()
  end

  defmodule ClientState do
    @moduledoc false
    defstruct type: nil,
              current_tx: 0,
              id: 0,
              pid: nil
  end

  @doc """
  Open a QMI device, or fetch the one already open on that path.

  One `Eqmi.Device` process serves each path and every caller in this VM
  shares it; the returned reference stays valid across restarts of the
  Device, but client references allocated from it do not (the restarted
  Device answers `{:error, :unknown_client}` for them, so allocate again).
  Only one operating-system process can usefully read a cdc-wdm device at
  a time, so two VMs opening the same path steal each other's responses.

  Options:

    * `:transport` - `:raw` (default, cdc-wdm QMUX) or `:mbim`
      (QMI-over-MBIM passthrough for a modem in MBIM mode)
  """
  @spec device(String.t(), keyword()) :: {:ok, reference()} | {:error, term()}
  def device(path, opts \\ []) do
    # the MBIM transport does a CLOSE/OPEN handshake in init, so allow time
    GenServer.call(__MODULE__, {:get_device, path, opts}, 15_000)
  end

  @doc "Close a device: its clients are released on the modem and the process stops."
  @spec close(reference()) :: :ok | {:error, :device_not_found}
  def close(dev_ref) do
    GenServer.call(__MODULE__, {:close_device, dev_ref}, 15_000)
  end

  def start_link(_args) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def stop(pid, reason \\ :shutdown, timeout \\ :infinity) do
    GenServer.stop(pid, reason, timeout)
  end

  def client(dev_ref, type) do
    with {:ok, path} <- GenServer.call(__MODULE__, {:get_path, dev_ref}) do
      Eqmi.Device.client(path, type)
    else
      err -> err
    end
  end

  def release_client(dev_ref, client_ref) do
    with {:ok, path} <- GenServer.call(__MODULE__, {:get_path, dev_ref}) do
      Eqmi.Device.release_client(path, client_ref)
    else
      err -> err
    end
  end

  def send_message(dev_ref, client_ref, msg) do
    with {:ok, path} <- GenServer.call(__MODULE__, {:get_path, dev_ref}) do
      Eqmi.Device.send_message(path, client_ref, msg)
    else
      err -> err
    end
  end

  @doc """
  Send a request and wait for its correlated response.

  Returns `{:ok, response}` or `{:error, reason}`. Unlike `send_message/3`,
  the reply is matched by transaction id so overlapping requests on one
  client don't get crossed. Indications are still delivered to the owner's
  mailbox as `{:qmux, msg}`.
  """
  def call(dev_ref, client_ref, msg, timeout \\ 5_000) do
    with {:ok, path} <- GenServer.call(__MODULE__, {:get_path, dev_ref}) do
      Eqmi.Device.call(path, client_ref, msg, timeout)
    else
      err -> err
    end
  end

  @doc """
  Introspection of a message params and returns, from the spec:
  `%{name, id, type, input: [tlv], output: [tlv]}`
  where each TLV has the `name` atom used in parameters, its
  `id`, `format` and, for sequences and arrays, `fields` or
  `element`.
  Nil if the service or message is unknown.

      iex> Eqmi.describe(:qmi_nas, :get_signal_strength).input
      [%{name: :request_mask, id: 16, format: "guint16"}]
  """
  @spec describe(atom(), atom()) :: map() | nil
  def describe(service, msg_name) do
    case Eqmi.Types.service_module(service) do
      nil -> nil
      mod -> mod.describe(msg_name)
    end
  end

  @doc "Every message and indication of a service, as `describe/2` returns them."
  @spec messages(atom()) :: [map()]
  def messages(service) do
    case Eqmi.Types.service_module(service) do
      nil -> []
      mod -> mod.messages()
    end
  end

  # `request_mask` overrides applied automatically when calling "get".
  # Without them the modem answers with the mandatory TLVs only,
  # which is rarely what a caller wants.
  @query_defaults %{
    {:qmi_nas, :get_signal_strength} => [request_mask: 0xFF],
    {:qmi_wds, :get_current_settings} => [requested_settings: 0xFFFFFFFF]
  }

  @doc """
  Default parameters added to `query/5` unless overriden by the caller passing the same key:
  Only `query/5` applies these; not applied to `request/2` and `call/4`.
  """
  @spec query_defaults(atom(), atom()) :: keyword()
  def query_defaults(service, msg_name), do: Map.get(@query_defaults, {service, msg_name}, [])

  @doc """
  Send one request and return the decoded response.

  `client` is a client reference from `client/2`, or a service atom such
  as `:qmi_nas` to use the device's shared client for that service, which
  is allocated on first use has the same lifetime as the device. Use the
  shared client for plain queries; allocate your own for anything with
  per-client state on the modem (a data call, indication registrations).

  `msg_name` and `params` are what the service module's `request/2` takes,
  e.g. `Eqmi.query(dev, :qmi_nas, :get_signal_info)` or
  `Eqmi.query(dev, wds, :start_network, apn: "internet")`; see
  `describe/2` for the parameter names and `query_defaults/2` for the
  inputs added for you.

    * `{:ok, params}` - the response parameters as a map keyed by TLV name
      (the result TLV is checked and left out)
    * `{:error, {:qmi, reason, params}}` - the modem answered with an error;
      `reason` is the error name from `Eqmi.Error` (or the code when unknown)
      and `params` the full parameter map, which for Start Network carries
      the call end reason
    * `{:error, :timeout}` or another `{:error, reason}` from the transport
  """
  def query(dev_ref, client, msg_name, params \\ [], timeout \\ 5_000) do
    with {:ok, path} <- GenServer.call(__MODULE__, {:get_path, dev_ref}),
         {:ok, client_ref, service} <- resolve_client(path, client),
         {:ok, mod} <- spec_module(service),
         params = Keyword.merge(query_defaults(service, msg_name), params),
         {:ok, resp} <-
           Eqmi.Device.call(path, client_ref, [mod.request(msg_name, params)], timeout) do
      query_result(resp)
    end
  end

  defp resolve_client(path, service) when is_atom(service) do
    with {:ok, ref} <- Eqmi.Device.shared_client(path, service), do: {:ok, ref, service}
  end

  defp resolve_client(path, client_ref) do
    with {:ok, service} <- Eqmi.Device.client_type(path, client_ref),
         do: {:ok, client_ref, service}
  end

  defp spec_module(service) do
    case Eqmi.Types.service_module(service) do
      nil -> {:error, {:no_spec, service}}
      mod -> {:ok, mod}
    end
  end

  defp query_result(%{messages: [%{parameters: params} | _]}) do
    case Map.pop(params, :result) do
      {%{error_status: 0}, rest} -> {:ok, rest}
      {%{error_code: code}, _} -> {:error, {:qmi, Eqmi.Error.protocol(code), params}}
      {nil, _} -> {:error, {:qmi, :no_result_tlv, params}}
    end
  end

  defp query_result(resp), do: {:error, {:bad_response, resp}}

  def init(_) do
    {:ok, %{devices: %{}, refs: %{}}}
  end

  def handle_call({:get_device, device_path, opts}, _from, state) do
    path = device_path |> String.trim()
    ref = Map.get(state.devices, path)

    # the Device may have been lost with its supervisor since it was opened;
    # a known path whose process is gone is started again under the same ref
    cond do
      ref != nil and Eqmi.Device.whereis(path) != nil ->
        {:reply, {:ok, ref}, state}

      true ->
        case DynamicSupervisor.start_child(
               Eqmi.DynamicSupervisor,
               {Eqmi.Device, [device: path] ++ opts}
             ) do
          {:ok, _pid} ->
            ref = ref || make_ref()

            state = %{
              state
              | devices: Map.put(state.devices, path, ref),
                refs: Map.put(state.refs, ref, path)
            }

            {:reply, {:ok, ref}, state}

          {:error, {:already_started, _pid}} ->
            ref = ref || make_ref()

            state = %{
              state
              | devices: Map.put(state.devices, path, ref),
                refs: Map.put(state.refs, ref, path)
            }

            {:reply, {:ok, ref}, state}

          {:error, error} ->
            {:reply, {:error, error}, state}
        end
    end
  end

  def handle_call({:close_device, ref}, _from, state) do
    case Map.pop(state.refs, ref) do
      {nil, _} ->
        {:reply, {:error, :device_not_found}, state}

      {path, refs} ->
        if pid = Eqmi.Device.whereis(path),
          do: DynamicSupervisor.terminate_child(Eqmi.DynamicSupervisor, pid)

        {:reply, :ok, %{state | devices: Map.delete(state.devices, path), refs: refs}}
    end
  end

  def handle_call({:get_path, ref}, _from, state) do
    case Map.get(state.refs, ref) do
      nil ->
        {:reply, {:error, :device_not_found}, state}

      path ->
        {:reply, {:ok, path}, state}
    end
  end

  def handle_info(msg, s) do
    Logger.warning("unexpected message in Eqmi: #{inspect(msg)}")
    {:noreply, s}
  end

  def terminate(reason, _s) do
    Logger.debug("Eqmi terminating: #{inspect(reason)}")
  end
end
