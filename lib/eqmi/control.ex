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
    defstruct device_name: nil,
              current_tx: 1,
              expected: nil,
              client_pid: nil
  end

  defp via_tuple(dev_name) do
    {:via, Registry, {:eqmi_registry, dev_name}}
  end

  defp base_name(device) do
    base_name = device |> String.trim() |> Path.basename()

    Module.concat(__MODULE__, base_name)
  end

  @doc """
  Start up a CallControl GenStateMachine.
  """
  @spec start_link([term]) :: {:ok, pid} | {:error, term}
  def start_link(device_name) do
    name =
      device_name
      |> base_name()
      |> via_tuple()

    GenStateMachine.start_link(__MODULE__, device_name, name: name)
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
  def init(dev_name) do
    data = %CTLState{device_name: dev_name}
    event = {:next_event, :cast, :sync}
    {:ok, :init_ctl, data, event}
  end

  def init_ctl(:cast, :sync, data) do
    data = send_request(data, :sync, [], @sync_msg_id)
    {:next_state, :wait4_sync, data, {:state_timeout, 10_000, :sync_response}}
  end

  def wait4_sync(:info, {:qmux, %{message_type: :response} = msg}, data) do
    if expected?(msg, data) do
      {:next_state, :idle, data}
    else
      stale(msg, data)
    end
  end

  def wait4_sync(:info, {:qmux, msg}, _data) do
    Logger.warning("Waiting 4 sync indication [#{inspect(msg)}]")
    :keep_state_and_data
  end

  def wait4_sync(:state_timeout, :sync_response, data) do
    Logger.error(
      "no response to QMI CTL sync on #{data.device_name}; " <>
        "device is not speaking raw QMUX (modem in MBIM mode?)"
    )

    {:next_state, :sync_failed, data}
  end

  def wait4_sync({:call, _from}, _msg, _data) do
    {:keep_state_and_data, [:postpone]}
  end

  # The device never answered the CTL sync request; answer callers with an
  # error instead of leaving them to hit their own call timeout.
  def sync_failed({:call, from}, _msg, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :sync_timeout}}]}
  end

  def sync_failed(:info, {:qmux, %{message_type: :response} = msg}, data) do
    if expected?(msg, data) do
      Logger.info("late sync response on #{data.device_name}, resuming")
      {:next_state, :idle, data}
    else
      stale(msg, data)
    end
  end

  def sync_failed(:info, _msg, _data) do
    :keep_state_and_data
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
    Logger.warning("Waiting 4 cid indication [#{inspect(msg)}]")
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
    Logger.warning("Waiting 4 release response [#{inspect(msg)}]")
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
