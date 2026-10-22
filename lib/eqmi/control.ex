defmodule Eqmi.Control do
  use GenStateMachine, callback_mode: :state_functions

  @sync_msg_id 0x27
  @allocation_msg_id 0x22
  @release_msg_id 0x23
  require Logger

  @moduledoc """
  CTL control point implementation.
  """
  defmodule CTLState do
    @moduledoc false
    # current_tx: next transaction id (one byte on the CTL service)
    # expected: {msg_id, tx_id} of the request in flight
    # client_pid: caller waiting for that request's response
    # sync_attempts: sync requests sent without an answer so far
    defstruct device_name: nil,
              current_tx: 1,
              expected: nil,
              client_pid: nil,
              sync_attempts: 0,
              sync_timeout: 10_000,
              resync_ms: 5_000
  end

  # The CTL sync (0x27) makes the modem drop every client ID it had handed
  # out and proves it is talking to us. A modem that has only just
  # enumerated may not answer yet, its QMI stack is still starting, so an
  # unanswered sync is sent again every :resync_ms until one is answered.
  # In between, callers get {:error, :sync_timeout} at once rather than
  # waiting out their own call timeout.

  defp via_tuple(dev_name) do
    {:via, Registry, {:eqmi_registry, dev_name}}
  end

  defp base_name(device) do
    base_name = device |> String.trim() |> Path.basename()

    Module.concat(__MODULE__, base_name)
  end

  @doc """
  Start the CTL control point for a device; it syncs with the modem first.

  Options (for tests): `:sync_timeout` - how long to wait for the sync
  response (default 10 s); `:resync_ms` - how long after an unanswered sync
  to send the next one (default 5 s).
  """
  @spec start_link(String.t(), keyword()) :: {:ok, pid} | {:error, term}
  def start_link(device_name, opts \\ []) do
    name =
      device_name
      |> base_name()
      |> via_tuple()

    GenStateMachine.start_link(__MODULE__, {device_name, opts}, name: name)
  end

  @doc """
  allocate client id for a service
  """
  @spec allocate_cid(String.t(), term()) :: {:ok, term()} | {:error, term}
  def allocate_cid(device_name, service) do
    device_name
    |> base_name()
    |> via_tuple()
    |> GenStateMachine.call({:allocate, service}, 12_000)
  end

  @spec release_cid(pid(), term(), term()) :: :ok | {:error, term}
  def release_cid(device_name, service, cid) do
    device_name
    |> base_name()
    |> via_tuple()
    |> GenStateMachine.call({:release, service, cid}, 6000)
  end

  # gen_state_machine callbacks
  def init({dev_name, opts}) do
    data = %CTLState{
      device_name: dev_name,
      sync_timeout: Keyword.get(opts, :sync_timeout, 10_000),
      resync_ms: Keyword.get(opts, :resync_ms, 5_000)
    }

    event = {:next_event, :cast, :sync}
    {:ok, :init_ctl, data, event}
  end

  def init_ctl(:cast, :sync, data) do
    send_sync(data)
  end

  def wait4_sync(:info, {:qmux, %{message_type: :response} = msg}, data) do
    if expected?(msg, data) do
      synced(data)
    else
      stale(msg, data)
    end
  end

  # the modem broadcasts a sync indication when any control point syncs,
  # our own request included, so one here says nothing new
  def wait4_sync(:info, {:qmux, msg}, _data) do
    Logger.debug("CTL message while waiting for the sync response: #{inspect(msg)}")
    :keep_state_and_data
  end

  def wait4_sync(:state_timeout, :sync_response, data) do
    # expected once after a cold start (the stack is not up yet), so a
    # warning; a device that never answers keeps failing at debug level
    if data.sync_attempts == 1 do
      Logger.warning(
        "no response to QMI CTL sync on #{data.device_name}; " <>
          "the modem is still starting, or the device is not speaking raw QMUX " <>
          "(modem in MBIM mode?); trying again every #{data.resync_ms} ms"
      )
    else
      Logger.debug("QMI CTL sync on #{data.device_name} unanswered (#{data.sync_attempts})")
    end

    {:next_state, :sync_failed, data, {:state_timeout, data.resync_ms, :resync}}
  end

  def wait4_sync({:call, _from}, _msg, _data) do
    {:keep_state_and_data, [:postpone]}
  end

  # The device has not answered a CTL sync yet: answer callers with an
  # error instead of leaving them to hit their own call timeout, and try
  # again shortly.
  def sync_failed({:call, from}, _msg, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :sync_timeout}}]}
  end

  def sync_failed(:state_timeout, :resync, data) do
    send_sync(data)
  end

  def sync_failed(:info, {:qmux, %{message_type: :response} = msg}, data) do
    if expected?(msg, data) do
      Logger.info("late sync response on #{data.device_name}, resuming")
      synced(data)
    else
      stale(msg, data)
    end
  end

  # the modem's QMI stack has just (re)started: ask it again now
  def sync_failed(:info, {:qmux, %{message_type: :indication} = msg}, data) do
    case msg.messages do
      [%{msg_id: @sync_msg_id} | _] -> send_sync(data)
      _ -> :keep_state_and_data
    end
  end

  def sync_failed(:info, _msg, _data) do
    :keep_state_and_data
  end

  defp send_sync(data) do
    data = %{send_request(data, :sync, [], @sync_msg_id) | sync_attempts: data.sync_attempts + 1}
    {:next_state, :wait4_sync, data, {:state_timeout, data.sync_timeout, :sync_response}}
  end

  defp synced(%CTLState{sync_attempts: n} = data) do
    if n > 1, do: Logger.info("QMI CTL sync on #{data.device_name} answered after #{n} attempts")
    {:next_state, :idle, %{data | sync_attempts: 0}}
  end

  def idle({:call, from}, {:allocate, service}, data) do
    service = Eqmi.service_type_id(service)
    data = send_request(data, :allocate_cid, [{:service, service}], @allocation_msg_id)
    {:next_state, :wait4_cid, %{data | client_pid: from}, {:state_timeout, 10_000, :cid_response}}
  end

  def idle({:call, from}, {:release, service, cid}, data) do
    service = Eqmi.service_type_id(service)
    params = [{:release_info, [service: service, cid: cid]}]
    data = send_request(data, :release_cid, params, @release_msg_id)

    {:next_state, :wait4_release, %{data | client_pid: from},
     {:state_timeout, 10_000, :release_response}}
  end

  def idle(:info, {:qmux, msg}, _data) do
    Logger.debug("unsolicited qmux message in idle: #{inspect(msg)}")
    :keep_state_and_data
  end

  def wait4_cid(:info, {:qmux, %{message_type: :response} = msg}, data) do
    if expected?(msg, data) do
      [h | _] = msg.messages

      response =
        case get_cid(h) do
          nil ->
            # surface the modem's error (e.g. client IDs exhausted)
            case qmi_result(msg) do
              :ok -> {:error, :cid_not_present}
              err -> err
            end

          cid ->
            {:ok, cid}
        end

      GenStateMachine.reply(data.client_pid, response)
      {:next_state, :idle, %{data | client_pid: nil}}
    else
      stale(msg, data)
    end
  end

  def wait4_cid(:info, {:qmux, msg}, _data) do
    Logger.debug("CTL message while waiting for the allocation response: #{inspect(msg)}")
    :keep_state_and_data
  end

  def wait4_cid(:state_timeout, :cid_response, data) do
    GenStateMachine.reply(data.client_pid, {:error, :timeout})
    new_data = %{data | client_pid: nil}
    {:next_state, :idle, new_data}
  end

  def wait4_cid({:call, _from}, _msg, _data) do
    {:keep_state_and_data, [:postpone]}
  end

  def wait4_release(:info, {:qmux, %{message_type: :response} = msg}, data) do
    if expected?(msg, data) do
      GenStateMachine.reply(data.client_pid, qmi_result(msg))
      {:next_state, :idle, %{data | client_pid: nil}}
    else
      stale(msg, data)
    end
  end

  def wait4_release(:info, {:qmux, msg}, _data) do
    Logger.debug("CTL message while waiting for the release response: #{inspect(msg)}")
    :keep_state_and_data
  end

  def wait4_release(:state_timeout, :release_response, data) do
    GenStateMachine.reply(data.client_pid, {:error, :timeout})
    new_data = %{data | client_pid: nil}
    {:next_state, :idle, new_data}
  end

  def wait4_release({:call, _from}, _msg, _data) do
    {:keep_state_and_data, [:postpone]}
  end

  defp get_cid(%{msg_id: @allocation_msg_id, parameters: %{allocation_info: %{cid: cid}}}) do
    cid
  end

  defp get_cid(_msg) do
    nil
  end

  defp qmi_result(%{messages: [%{parameters: params} | _]}) do
    case Map.get(params, :result) do
      %{error_status: 0, error_code: 0} -> :ok
      nil -> {:error, :no_result_tlv}
      result -> {:error, {:qmi_error, result}}
    end
  end

  defp qmi_result(_msg) do
    {:error, :bad_response}
  end

  # Send a CTL request and remember which response belongs to it. cdc-wdm
  # keeps unread data across close and reopen, so the first response seen
  # may be a leftover from an earlier process (typically the release of a
  # client that was being torn down); only the matching one is accepted.
  defp send_request(%CTLState{current_tx: tx} = data, msg_type, params, msg_id) do
    msg = Eqmi.CTL.request(msg_type, params)
    payload = Eqmi.CTL.qmux_sdu(:request, tx, [msg])
    header = Eqmi.QmuxHeader.new(:control_point, 0, :qmi_ctl, byte_size(payload))
    Eqmi.Device.send_raw(data.device_name, Eqmi.qmux_message(header, payload))
    %{data | expected: {msg_id, tx}, current_tx: next_tx(tx)}
  end

  # CTL transaction ids are one byte and 0 is reserved
  defp next_tx(255), do: 1
  defp next_tx(tx), do: tx + 1

  defp expected?(%{tx_id: tx, messages: [%{msg_id: id} | _]}, %CTLState{expected: {id, tx}}),
    do: true

  defp expected?(_msg, _data), do: false

  defp stale(msg, %CTLState{expected: {id, tx}} = data) do
    Logger.debug(
      "#{data.device_name}: ignoring CTL response #{inspect(msg.messages |> hd() |> Map.get(:name))} " <>
        "tx #{msg.tx_id} while waiting for message #{id} tx #{tx}"
    )

    :keep_state_and_data
  end
end
