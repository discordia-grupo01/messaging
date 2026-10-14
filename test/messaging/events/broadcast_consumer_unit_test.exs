defmodule Messaging.Events.BroadcastConsumerUnitTest do
  use ExUnit.Case, async: true

  alias Messaging.Events.BroadcastConsumer

  @unreachable_url "amqp://guest:guest@127.0.0.1:1/"

  test "init/1 starts disconnected and schedules a connect attempt" do
    assert {:ok, %{url: @unreachable_url, backoff: backoff, conn: nil, chan: nil}} =
             BroadcastConsumer.init(url: @unreachable_url)

    assert_received :connect
    assert backoff > 0
  end

  test "init/1 gives each instance its own queue name, kept across reconnections" do
    {:ok, %{queue: first}} = BroadcastConsumer.init(url: @unreachable_url)
    {:ok, %{queue: second}} = BroadcastConsumer.init(url: @unreachable_url)

    assert String.starts_with?(first, "messaging.broadcast.")
    assert first != second

    {:noreply, %{queue: after_down}} =
      BroadcastConsumer.handle_info(
        {:DOWN, make_ref(), :process, self(), :shutdown},
        %{url: @unreachable_url, queue: first, backoff: 1_000, conn: :c, chan: :ch}
      )

    assert after_down == first
  end

  test "handle_info(:connect, ...) backs off and stays disconnected when the broker is unreachable" do
    state = %{url: @unreachable_url, queue: "q", backoff: 50, conn: nil, chan: nil}

    assert {:noreply, %{conn: nil, chan: nil, backoff: 100}} =
             BroadcastConsumer.handle_info(:connect, state)

    assert_receive :connect, 500
  end

  test "handle_info({:DOWN, ...}) resets state and retries" do
    state = %{
      url: @unreachable_url,
      queue: "q",
      backoff: 30_000,
      conn: :fake_conn,
      chan: :fake_chan
    }

    assert {:noreply, %{conn: nil, chan: nil, backoff: backoff}} =
             BroadcastConsumer.handle_info(
               {:DOWN, make_ref(), :process, self(), :shutdown},
               state
             )

    assert backoff < 30_000
    assert_received :connect
  end

  test "handle_info({:basic_consume_ok, ...}) is a no-op" do
    state = %{url: @unreachable_url, queue: "q", backoff: 1_000, conn: nil, chan: nil}
    assert {:noreply, ^state} = BroadcastConsumer.handle_info({:basic_consume_ok, %{}}, state)
  end

  test "handle_info({:basic_cancel, ...}) stops the GenServer" do
    state = %{url: @unreachable_url, queue: "q", backoff: 1_000, conn: nil, chan: nil}
    assert {:stop, :normal, ^state} = BroadcastConsumer.handle_info({:basic_cancel, %{}}, state)
  end

  test "handle_info({:basic_cancel_ok, ...}) is a no-op" do
    state = %{url: @unreachable_url, queue: "q", backoff: 1_000, conn: nil, chan: nil}
    assert {:noreply, ^state} = BroadcastConsumer.handle_info({:basic_cancel_ok, %{}}, state)
  end

  test "handle_info({:EXIT, ...}) is ignored so the DOWN handler can reconnect" do
    state = %{
      url: @unreachable_url,
      queue: "q",
      backoff: 1_000,
      conn: :fake_conn,
      chan: :fake_chan
    }

    assert {:noreply, ^state} = BroadcastConsumer.handle_info({:EXIT, self(), :killed}, state)
  end

  test "terminate/2 closes the connection and never raises, even if it is already gone" do
    {:ok, conn} = Agent.start(fn -> :not_an_amqp_connection end)

    assert :ok = BroadcastConsumer.terminate(:shutdown, %{conn: %{pid: conn}})
    assert :ok = BroadcastConsumer.terminate(:shutdown, %{conn: nil})
  end
end
