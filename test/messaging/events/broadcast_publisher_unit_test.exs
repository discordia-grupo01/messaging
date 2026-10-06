defmodule Messaging.Events.BroadcastPublisherUnitTest do
  use ExUnit.Case, async: true

  alias Messaging.Events.BroadcastPublisher

  @unreachable_url "amqp://guest:guest@127.0.0.1:1/"

  test "init/1 starts disconnected and schedules a connect attempt" do
    assert {:ok, %{url: @unreachable_url, backoff: backoff, conn: nil, chan: nil}} =
             BroadcastPublisher.init(url: @unreachable_url)

    assert_received :connect
    assert backoff > 0
  end

  test "handle_call({:publish, _}, ...) errors out while disconnected instead of hanging" do
    state = %{url: @unreachable_url, backoff: 1_000, conn: nil, chan: nil}

    assert {:reply, {:error, :not_connected}, ^state} =
             BroadcastPublisher.handle_call(
               {:publish, "channel:c1", "new_message", %{"channel_id" => "c1"}},
               {self(), make_ref()},
               state
             )
  end

  test "handle_info(:connect, ...) backs off and stays disconnected when the broker is unreachable" do
    state = %{url: @unreachable_url, backoff: 50, conn: nil, chan: nil}

    assert {:noreply, %{conn: nil, chan: nil, backoff: 100}} =
             BroadcastPublisher.handle_info(:connect, state)

    assert_receive :connect, 500
  end

  test "handle_info({:DOWN, ...}) resets state and retries" do
    state = %{url: @unreachable_url, backoff: 30_000, conn: :fake_conn, chan: :fake_chan}

    assert {:noreply, %{conn: nil, chan: nil, backoff: backoff}} =
             BroadcastPublisher.handle_info(
               {:DOWN, make_ref(), :process, self(), :shutdown},
               state
             )

    assert backoff < 30_000
    assert_received :connect
  end

  test "handle_info({:EXIT, ...}) is ignored so the DOWN handler can reconnect" do
    state = %{url: @unreachable_url, backoff: 1_000, conn: :fake_conn, chan: :fake_chan}

    assert {:noreply, ^state} = BroadcastPublisher.handle_info({:EXIT, self(), :killed}, state)
  end

  test "terminate/2 closes the connection and never raises, even if it is already gone" do
    {:ok, conn} = Agent.start(fn -> :not_an_amqp_connection end)

    assert :ok = BroadcastPublisher.terminate(:shutdown, %{conn: %{pid: conn}})
    assert :ok = BroadcastPublisher.terminate(:shutdown, %{conn: nil})
  end
end
