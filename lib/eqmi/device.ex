defmodule Eqmi.Device do
  use GenServer
  require Logger

  @ctl_id 0

  defmodule ClientState do
    @moduledoc false
    defstruct type: nil,
              current_tx: 0,
              id: 0,
              pid: nil
  end

  def start_link(args) do
    device = Keyword.fetch!(args, :device)
    name = device |> base_name() |> via_tuple()
    GenServer.start_link(__MODULE__, args, name: name)
  end

  defp via_tuple(dev_name) do
    {:via, Registry, {:eqmi_registry, dev_name}}
  end

  defp base_name(device) do
    base_name = device |> String.trim() |> Path.basename()

    Module.concat(__MODULE__, base_name)
  end

  @doc "Pid of the Device serving a path, or nil when none is running."
  def whereis(device) do
    case Registry.lookup(:eqmi_registry, base_name(device)) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def stop(dev_name, reason \\ :shutdown, timeout \\ :infinity) do
    dev_name
    |> base_name()
    |> via_tuple()
    |> GenServer.stop(reason, timeout)
  end

  def client(dev_name, type) do
    case Eqmi.Control.allocate_cid(dev_name, type) do
      {:ok, cid} ->
        dev_name
        |> base_name()
        |> via_tuple()
        |> GenServer.call({:new_client, type, cid})

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, "allocating control point"}
    end
  end

  def release_client(dev_name, ref) do
    name =
      dev_name
      |> base_name()
      |> via_tuple()

    with {:ok, client} <- GenServer.call(name, {:get_client, ref}) do
      Eqmi.Control.release_cid(dev_name, client.type, client.id)
      GenServer.call(name, {:release, ref})
    else
      err -> err
    end
  end

  @doc """
  The device's shared client for a service, allocated on first use and
  owned by the device itself (released when the device stops). Indications
  arriving on it are dropped.
  """
  def shared_client(dev_name, type) do
    name = dev_name |> base_name() |> via_tuple()

    case GenServer.call(name, {:shared_client, type}) do
      {:ok, ref} ->
        {:ok, ref}

      :none ->
        case Eqmi.Control.allocate_cid(dev_name, type) do
          {:ok, cid} -> GenServer.call(name, {:new_shared_client, type, cid})
          {:error, reason} -> {:error, reason}
          other -> {:error, {:allocate, other}}
        end
    end
  end

  @doc "Service type (e.g. `:qmi_nas`) of an allocated client."
  def client_type(dev_name, ref) do
    with {:ok, client} <- GenServer.call(base_name(dev_name) |> via_tuple(), {:get_client, ref}) do
      {:ok, client.type}
    end
  end

  def send_message(dev_name, ref, msg) do
    dev_name
    |> base_name()
    |> via_tuple()
    |> GenServer.call({:send_msg, ref, msg})
  end

  @doc """
  Send request messages and wait for the response with the matching
  transaction id, so concurrent requests on one client cannot pick up
  each other's replies. Indications still go to the owner's mailbox.
  """
  def call(dev_name, ref, msg, timeout \\ 5_000) do
    dev_name
    |> base_name()
    |> via_tuple()
    |> GenServer.call({:call_msg, ref, msg, timeout}, timeout + 1_000)
  end

  def send_raw(dev_name, msg) do
    dev_name
    |> base_name()
    |> via_tuple()
    |> GenServer.call({:send_raw, msg})
  end

  def init(args) do
    device = Keyword.fetch!(args, :device)
    transport = Keyword.get(args, :transport, :raw)
    options = [:write, :raw]
    # so terminate/2 runs on supervisor shutdown and the clients get released
    Process.flag(:trap_exit, true)

    case File.open(device, options) do
      {:ok, dev} ->
        {:ok, reader} = Eqmi.Reader.start_link(self(), device, transport)

        state = %{
          reader: reader,
          device: dev,
          device_name: device,
          transport: transport,
          mbim_tx: 1,
          control_points: %{},
          clients: %{},
          shared: %{},
          pending: %{},
          ctl: nil
        }

        # Finish the transport handshake (a no-op for raw) before starting
        # Control, so the device is fully usable the moment init returns.
        case open_transport(state) do
          {:ok, state} -> {:ok, start_control(state)}
          {:error, reason} -> {:stop, reason}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  # Raw QMUX is ready immediately; MBIM must complete an OPEN handshake
  # before any QMI command is accepted. The reader delivers OPEN_DONE to us,
  # so block init on it (bounded) - the mailbox holds it until we read.
  #
  # A previous client that exited without closing leaves the session open,
  # and this class of modem won't answer a fresh OPEN on an open session, so
  # CLOSE first (best effort) to reset it.
  defp open_transport(%{transport: :raw} = s), do: {:ok, s}

  defp open_transport(%{transport: :mbim} = s) do
    s = mbim_close(s)

    IO.binwrite(s.device, Eqmi.Mbim.open(s.mbim_tx))
    s = %{s | mbim_tx: s.mbim_tx + 1}

    receive do
      {:mbim_open_done, 0} ->
        Logger.info("MBIM opened on #{s.device_name}")
        {:ok, s}

      {:mbim_open_done, status} ->
        Logger.error("MBIM OPEN failed on #{s.device_name}: status #{status}")
        {:error, {:mbim_open, status}}

      {:error, reason} ->
        Logger.error("MBIM reader error during open on #{s.device_name}: #{inspect(reason)}")
        {:error, {:reader, reason}}
    after
      5_000 ->
        Logger.error("MBIM OPEN timed out on #{s.device_name} (device may be wedged)")
        {:error, :mbim_open_timeout}
    end
  end

  # Best-effort MBIM CLOSE: wait briefly for CLOSE_DONE, but proceed either
  # way (a fresh/closed session simply won't answer).
  defp mbim_close(s) do
    IO.binwrite(s.device, Eqmi.Mbim.close(s.mbim_tx))

    receive do
      {:mbim_close_done, _status} -> :ok
    after
      1_000 -> :ok
    end

    %{s | mbim_tx: s.mbim_tx + 1}
  end

  defp start_control(s) do
    {:ok, ctl} = Eqmi.Control.start_link(s.device_name)
    %{s | ctl: ctl, clients: %{:qmi_ctl => %{@ctl_id => ctl}}}
  end

  # Wrap an outgoing QMUX message for the active transport and write it,
  # returning the write result and the (possibly tx-advanced) state.
  defp write_qmux(%{transport: :mbim, device: dev, mbim_tx: tx} = s, qmux_msg) do
    res = IO.binwrite(dev, Eqmi.Mbim.command(tx, qmux_msg))
    {res, %{s | mbim_tx: tx + 1}}
  end

  defp write_qmux(%{device: dev} = s, qmux_msg) do
    {IO.binwrite(dev, qmux_msg), s}
  end

  # Build a service request frame and return the transaction id used, so
  # a caller can correlate the response. tx_id wraps within the 16-bit
  # field, skipping 0.
  defp build_client_msg(client, msg) do
    tx_id = next_tx(client.current_tx)
    payload = qmux_sdu(client.type, :request, tx_id, msg)
    header = Eqmi.QmuxHeader.new(:control_point, client.id, client.type, byte_size(payload))
    qmux_msg = Eqmi.qmux_message(header, payload)
    {tx_id, qmux_msg}
  end

  defp next_tx(tx) when tx >= 0xFFFF, do: 1
  defp next_tx(tx), do: tx + 1

  def handle_call(:get_ctl, _from, s) do
    {:reply, {:ok, s.ctl}, s}
  end

  def handle_call({:new_client, type, cid}, from, %{clients: clients, control_points: ctrls} = s) do
    {pid, _} = from
    client_state = %ClientState{type: type, id: cid, current_tx: 0, pid: pid}
    ref = Process.monitor(pid)

    clients_ids =
      clients
      |> Map.get(type, %{})
      |> Map.put(cid, pid)

    new_clients = Map.put(clients, type, clients_ids)
    new_ctrls = Map.put(ctrls, ref, client_state)
    state = %{s | clients: new_clients, control_points: new_ctrls}
    {:reply, ref, state}
  end

  def handle_call({:release, ref}, _from, s) do
    new_state = release_base(ref, s)
    {:reply, :ok, new_state}
  end

  def handle_call({:shared_client, type}, _from, %{shared: shared} = s) do
    case Map.fetch(shared, type) do
      {:ok, ref} -> {:reply, {:ok, ref}, s}
      :error -> {:reply, :none, s}
    end
  end

  def handle_call({:new_shared_client, type, cid}, _from, %{shared: shared} = s) do
    case Map.fetch(shared, type) do
      {:ok, ref} ->
        # another caller got there first: give the spare CID back
        device = s.device_name
        Task.start(fn -> Eqmi.Control.release_cid(device, type, cid) end)
        {:reply, {:ok, ref}, s}

      :error ->
        ref = make_ref()
        client_state = %ClientState{type: type, id: cid, current_tx: 0, pid: self()}
        clients_ids = s.clients |> Map.get(type, %{}) |> Map.put(cid, self())

        s = %{
          s
          | clients: Map.put(s.clients, type, clients_ids),
            control_points: Map.put(s.control_points, ref, client_state),
            shared: Map.put(shared, type, ref)
        }

        {:reply, {:ok, ref}, s}
    end
  end

  def handle_call({:get_client, ref}, _from, %{control_points: controls} = s) do
    client = Map.get(controls, ref)

    if client != nil do
      {:reply, {:ok, client}, s}
    else
      {:reply, {:error, :unknown_client}, s}
    end
  end

  def handle_call(
        {:send_msg, ref, msg},
        _from,
        %{control_points: controls} = s
      ) do
    case Map.get(controls, ref) do
      %ClientState{} = client ->
        {tx_id, qmux_msg} = build_client_msg(client, msg)
        {res, s} = write_qmux(s, qmux_msg)
        new_ctrls = Map.put(controls, ref, %{client | current_tx: tx_id})

        {:reply, res, %{s | control_points: new_ctrls}}

      nil ->
        {:reply, {:error, :unknown_client}, s}
    end
  end

  def handle_call(
        {:call_msg, ref, msg, timeout},
        from,
        %{control_points: controls} = s
      ) do
    case Map.get(controls, ref) do
      %ClientState{} = client ->
        {tx_id, qmux_msg} = build_client_msg(client, msg)
        {write_res, s} = write_qmux(s, qmux_msg)
        new_ctrls = Map.put(controls, ref, %{client | current_tx: tx_id})

        case write_res do
          :ok ->
            key = {client.type, client.id, tx_id}
            timer = Process.send_after(self(), {:call_timeout, key}, timeout)
            pending = Map.put(s.pending, key, {from, timer})
            {:noreply, %{s | control_points: new_ctrls, pending: pending}}

          err ->
            {:reply, {:error, err}, %{s | control_points: new_ctrls}}
        end

      nil ->
        {:reply, {:error, :unknown_client}, s}
    end
  end

  def handle_call({:send_raw, msg}, _from, s) do
    {res, s} = write_qmux(s, msg)
    {:reply, res, s}
  end

  def handle_info({:qmux, header, messages}, %{clients: clients, pending: pending} = s) do
    # a decoder bug must not take the whole device down; drop the
    # message and keep serving the other clients
    try do
      msg = process_service(header, messages)
      key = {header.service_type, header.client_id, Map.get(msg, :tx_id)}

      case Map.get(pending, key) do
        {from, timer} when :erlang.map_get(:message_type, msg) == :response ->
          Process.cancel_timer(timer)
          GenServer.reply(from, {:ok, msg})
          {:noreply, %{s | pending: Map.delete(pending, key)}}

        _ ->
          # indication, or a response nobody is awaiting via call/4:
          # deliver to the owning client's mailbox
          client = find_client(clients, header.service_type, header.client_id)
          if client != nil, do: send(client, {:qmux, msg})
          {:noreply, s}
      end
    rescue
      e ->
        Logger.error(
          "failed to decode qmux message #{inspect(header)} " <>
            "payload #{inspect(messages, base: :hex, limit: 128)}: #{Exception.message(e)}"
        )

        {:noreply, s}
    end
  end

  def handle_info({:call_timeout, key}, %{pending: pending} = s) do
    case Map.pop(pending, key) do
      {{from, _timer}, rest} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{s | pending: rest}}

      {nil, _} ->
        {:noreply, s}
    end
  end

  def handle_info({:DOWN, ref, :process, _object, _reason}, state) do
    # release the CID on the modem too, or it stays allocated until the
    # modem reboots; async because Control calls back into this server
    # to write to the device
    case Map.get(state.control_points, ref) do
      nil ->
        :ok

      cp ->
        device = state.device_name
        Task.start(fn -> Eqmi.Control.release_cid(device, cp.type, cp.id) end)
    end

    new_state = release_base(ref, state)
    {:noreply, new_state}
  end

  # an indication on a shared client: nobody owns it, so drop it
  def handle_info({:qmux, msg}, s) do
    Logger.debug("indication on the shared client dropped: #{inspect(msg)}")
    {:noreply, s}
  end

  # the reader or the CTL state machine died; without either we are deaf,
  # so stop and let the supervisor start a fresh device
  def handle_info({:EXIT, pid, reason}, %{reader: pid} = s) do
    {:stop, {:shutdown, {:reader_error, reason}}, s}
  end

  def handle_info({:EXIT, pid, reason}, %{ctl: pid} = s) do
    {:stop, {:shutdown, {:control_error, reason}}, s}
  end

  def handle_info({:EXIT, _pid, _reason}, s), do: {:noreply, s}

  def handle_info({:error, reason}, s) do
    # the reader died or hit EOF; without it we are deaf, so restart the
    # whole device via the supervisor
    Logger.error("qmux reader failed on #{s.device_name}: #{inspect(reason)}")
    {:stop, {:shutdown, {:reader_error, reason}}, s}
  end

  def handle_info(msg, s) do
    Logger.warning("unexpected message in Eqmi.Device: #{inspect(msg)}")
    {:noreply, s}
  end

  # Runs on every orderly stop: a {:stop, _} return (reader or Control
  # died, reader hit EOF), GenServer.stop, and the supervisor's shutdown
  # (application stop, SIGTERM, Eqmi.close/1) because init traps exits. It
  # cannot run after a :kill or a VM abort; the CTL sync of the next open
  # releases whatever those leave behind. The device may already be gone
  # (unplugged), and a write to a dead descriptor raises, so nothing in
  # here is allowed to abort the close.
  def terminate(_reason, s) do
    try do
      s = release_all(s)
      # close the MBIM session so the next client can OPEN cleanly
      if s.transport == :mbim, do: IO.binwrite(s.device, Eqmi.Mbim.close(s.mbim_tx))
    rescue
      e -> Logger.debug("#{s.device_name}: cleanup on stop skipped: #{Exception.message(e)}")
    after
      File.close(s.device)
    end

    :ok
  end

  # Give every client ID back to the modem before closing. Fire and forget:
  # Control cannot be used from terminate/2 (it calls back into this
  # process) and the responses are not needed. CIDs that still leak (the
  # VM was killed) are released by the CTL sync of the next open.
  defp release_all(%{control_points: controls} = s) do
    controls
    |> Map.values()
    |> Enum.with_index(1)
    |> Enum.reduce(s, fn {cp, tx}, s ->
      msg =
        Eqmi.CTL.request(:release_cid,
          release_info: [service: Eqmi.service_type_id(cp.type), cid: cp.id]
        )

      payload = Eqmi.CTL.qmux_sdu(:request, rem(tx, 255) + 1, [msg])
      header = Eqmi.QmuxHeader.new(:control_point, 0, :qmi_ctl, byte_size(payload))
      {_res, s} = write_qmux(s, Eqmi.qmux_message(header, payload))
      s
    end)
  end

  defp release_base(ref, %{clients: clients, control_points: controls} = s) do
    case Map.get(controls, ref) do
      nil ->
        # already released; the monitor :DOWN for an explicitly released
        # client ends up here
        s

      control_point ->
        Process.demonitor(ref, [:flush])
        new_controls = Map.delete(controls, ref)

        new_client_list =
          clients
          |> Map.get(control_point.type, %{})
          |> Map.delete(control_point.id)

        new_clients = Map.put(clients, control_point.type, new_client_list)
        %{s | clients: new_clients, control_points: new_controls}
    end
  end

  defp find_client(clients, service_type, client_id) do
    clients
    |> Map.get(service_type, %{})
    |> Map.get(client_id)
  end

  defp process_service(%{service_type: :qmi_ctl} = payload, messages) do
    Eqmi.CTL.process_qmux_sdu(messages, payload)
  end

  defp process_service(%{service_type: :qmi_wds} = payload, messages) do
    Eqmi.WDS.process_qmux_sdu(messages, payload)
  end

  defp process_service(%{service_type: :qmi_dms} = payload, messages) do
    Eqmi.DMS.process_qmux_sdu(messages, payload)
  end

  defp process_service(%{service_type: :qmi_dpm} = payload, messages) do
    Eqmi.DPM.process_qmux_sdu(messages, payload)
  end

  defp process_service(%{service_type: :qmi_dsd} = payload, messages) do
    Eqmi.DSD.process_qmux_sdu(messages, payload)
  end

  defp process_service(%{service_type: :qmi_nas} = payload, messages) do
    Eqmi.NAS.process_qmux_sdu(messages, payload)
  end

  defp process_service(%{service_type: :qmi_qos} = payload, messages) do
    Eqmi.QOS.process_qmux_sdu(messages, payload)
  end

  defp process_service(%{service_type: :qmi_pdc} = payload, messages) do
    Eqmi.PDC.process_qmux_sdu(messages, payload)
  end

  defp process_service(%{service_type: :qmi_wms} = payload, messages) do
    Eqmi.WMS.process_qmux_sdu(messages, payload)
  end

  defp process_service(%{service_type: :qmi_pds} = payload, messages) do
    Eqmi.PDS.process_qmux_sdu(messages, payload)
  end

  defp process_service(%{service_type: :qmi_voice} = payload, messages) do
    Eqmi.VOICE.process_qmux_sdu(messages, payload)
  end

  defp process_service(%{service_type: :qmi_pbm} = payload, messages) do
    Eqmi.PBM.process_qmux_sdu(messages, payload)
  end

  defp process_service(%{service_type: :qmi_uim} = payload, messages) do
    Eqmi.UIM.process_qmux_sdu(messages, payload)
  end

  defp process_service(%{service_type: :qmi_loc} = payload, messages) do
    Eqmi.LOC.process_qmux_sdu(messages, payload)
  end

  defp process_service(%{service_type: :qmi_sar} = payload, messages) do
    Eqmi.SAR.process_qmux_sdu(messages, payload)
  end

  defp process_service(%{service_type: :qmi_wda} = payload, messages) do
    Eqmi.WDA.process_qmux_sdu(messages, payload)
  end

  defp process_service(%{service_type: :qmi_oma} = payload, messages) do
    Eqmi.OMA.process_qmux_sdu(messages, payload)
  end

  defp process_service(%{service_type: :qmi_gms} = payload, messages) do
    Eqmi.GMS.process_qmux_sdu(messages, payload)
  end

  defp process_service(%{service_type: :qmi_gas} = payload, messages) do
    Eqmi.GAS.process_qmux_sdu(messages, payload)
  end

  defp qmux_sdu(:qmi_ctl, msg_type, tx_id, messages) do
    Eqmi.CTL.qmux_sdu(msg_type, tx_id, messages)
  end

  defp qmux_sdu(:qmi_wds, msg_type, tx_id, messages) do
    Eqmi.WDS.qmux_sdu(msg_type, tx_id, messages)
  end

  defp qmux_sdu(:qmi_dms, msg_type, tx_id, messages) do
    Eqmi.DMS.qmux_sdu(msg_type, tx_id, messages)
  end

  defp qmux_sdu(:qmi_dpm, msg_type, tx_id, messages) do
    Eqmi.DPM.qmux_sdu(msg_type, tx_id, messages)
  end

  defp qmux_sdu(:qmi_dsd, msg_type, tx_id, messages) do
    Eqmi.DSD.qmux_sdu(msg_type, tx_id, messages)
  end

  defp qmux_sdu(:qmi_nas, msg_type, tx_id, messages) do
    Eqmi.NAS.qmux_sdu(msg_type, tx_id, messages)
  end

  defp qmux_sdu(:qmi_qos, msg_type, tx_id, messages) do
    Eqmi.QOS.qmux_sdu(msg_type, tx_id, messages)
  end

  defp qmux_sdu(:qmi_pdc, msg_type, tx_id, messages) do
    Eqmi.PDC.qmux_sdu(msg_type, tx_id, messages)
  end

  defp qmux_sdu(:qmi_wms, msg_type, tx_id, messages) do
    Eqmi.WMS.qmux_sdu(msg_type, tx_id, messages)
  end

  defp qmux_sdu(:qmi_pds, msg_type, tx_id, messages) do
    Eqmi.PDS.qmux_sdu(msg_type, tx_id, messages)
  end

  defp qmux_sdu(:qmi_voice, msg_type, tx_id, messages) do
    Eqmi.VOICE.qmux_sdu(msg_type, tx_id, messages)
  end

  defp qmux_sdu(:qmi_pbm, msg_type, tx_id, messages) do
    Eqmi.PBM.qmux_sdu(msg_type, tx_id, messages)
  end

  defp qmux_sdu(:qmi_uim, msg_type, tx_id, messages) do
    Eqmi.UIM.qmux_sdu(msg_type, tx_id, messages)
  end

  defp qmux_sdu(:qmi_loc, msg_type, tx_id, messages) do
    Eqmi.LOC.qmux_sdu(msg_type, tx_id, messages)
  end

  defp qmux_sdu(:qmi_sar, msg_type, tx_id, messages) do
    Eqmi.SAR.qmux_sdu(msg_type, tx_id, messages)
  end

  defp qmux_sdu(:qmi_wda, msg_type, tx_id, messages) do
    Eqmi.WDA.qmux_sdu(msg_type, tx_id, messages)
  end

  defp qmux_sdu(:qmi_oma, msg_type, tx_id, messages) do
    Eqmi.OMA.qmux_sdu(msg_type, tx_id, messages)
  end

  defp qmux_sdu(:qmi_gms, msg_type, tx_id, messages) do
    Eqmi.GMS.qmux_sdu(msg_type, tx_id, messages)
  end

  defp qmux_sdu(:qmi_gas, msg_type, tx_id, messages) do
    Eqmi.GAS.qmux_sdu(msg_type, tx_id, messages)
  end
end
