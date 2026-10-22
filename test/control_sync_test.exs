defmodule EqmiControlSyncTest do
  use ExUnit.Case

  # A stand-in for Eqmi.Device: takes the frames Control writes and hands
  # them to the test, so the CTL state machine runs without a modem.
  defmodule FakeDevice do
    use GenServer

    def start_link({device, test}) do
      name = {:via, Registry, {:eqmi_registry, Module.concat(Eqmi.Device, Path.basename(device))}}
      GenServer.start_link(__MODULE__, test, name: name)
    end

    def init(test), do: {:ok, test}

    def handle_call({:send_raw, frame}, _from, test) do
      send(test, {:sent, frame})
      {:reply, :ok, test}
    end
  end

  @sync 0x27
  @allocate 0x22

  setup do
    device = "/dev/ctl-test-#{System.unique_integer([:positive])}"
    start_supervised!({FakeDevice, {device, self()}})
    %{device: device}
  end

  test "an unanswered sync is sent again, and callers are told meanwhile", %{device: device} do
    ctl = start_control(device, sync_timeout: 100, resync_ms: 100)

    assert_receive {:sent, frame1}, 500
    assert {:ok, tx1} = sync_tx(frame1)

    # while the sync is unanswered, a caller gets an answer rather than a hang
    task = Task.async(fn -> Eqmi.Control.allocate_cid(device, :qmi_dms) end)
    assert {:error, :sync_timeout} = Task.await(task, 1_000)

    assert_receive {:sent, frame2}, 500
    assert {:ok, tx2} = sync_tx(frame2)
    assert tx2 == tx1 + 1

    # the second one is answered: the control point is usable
    send(ctl, {:qmux, sync_response(tx2)})
    task = Task.async(fn -> Eqmi.Control.allocate_cid(device, :qmi_dms) end)
    assert_receive {:sent, frame3}, 500
    assert {:ok, tx3} = request_tx(frame3, @allocate)
    send(ctl, {:qmux, allocate_response(tx3, 2, 7)})
    assert {:ok, 7} = Task.await(task, 1_000)
  end

  test "the modem's sync indication while failed brings a new sync at once", %{device: device} do
    ctl = start_control(device, sync_timeout: 100, resync_ms: 60_000)
    assert_receive {:sent, _first}, 500
    # wait out the sync timeout: now failed, next retry a minute away
    Process.sleep(200)
    refute_received {:sent, _}
    send(ctl, {:qmux, sync_indication()})
    assert_receive {:sent, frame}, 200
    assert {:ok, _} = sync_tx(frame)
  end

  test "a sync indication while waiting does not start another sync", %{device: device} do
    ctl = start_control(device, sync_timeout: 2_000, resync_ms: 60_000)
    assert_receive {:sent, _first}, 500
    # the modem broadcasts one in answer to our own request
    send(ctl, {:qmux, sync_indication()})
    refute_receive {:sent, _}, 300
  end

  defp start_control(device, opts) do
    start_supervised!(%{id: Eqmi.Control, start: {Eqmi.Control, :start_link, [device, opts]}})
  end

  # --- CTL frames --------------------------------------------------------

  # frame: 0x01, len (2), ctrl flags, service 0, client 0 | sdu: flags, tx, msg id (2) ...
  defp request_tx(<<1, _len::little-16, _flags, 0, 0, 0, tx, id::little-16, _::binary>>, id),
    do: {:ok, tx}

  defp request_tx(frame, _id), do: {:error, frame}

  defp sync_tx(frame), do: request_tx(frame, @sync)

  defp sync_response(tx) do
    ctl_message(:response, tx, @sync, :sync, %{result: %{error_status: 0, error_code: 0}})
  end

  defp sync_indication do
    ctl_message(:indication, 0, @sync, :sync, %{})
  end

  defp allocate_response(tx, service, cid) do
    ctl_message(:response, tx, @allocate, :allocate_cid, %{
      result: %{error_status: 0, error_code: 0},
      allocation_info: %{service: service, cid: cid}
    })
  end

  defp ctl_message(type, tx, id, name, params) do
    %{
      message_type: type,
      sender_type: :service,
      service_type: :qmi_ctl,
      client_id: 0,
      tx_id: tx,
      messages: [%{msg_id: id, name: name, parameters: params}]
    }
  end
end
