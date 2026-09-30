defmodule Messaging.Events.ChannelLifecycleConsumerUnitTest do
  use ExUnit.Case, async: true

  alias Messaging.Events.ChannelLifecycleConsumer

  @unreachable_url "amqp://guest:guest@127.0.0.1:1/"
  @queue "messaging.channel_lifecycle"

  test "init/1 starts disconnected and schedules a connect attempt" do
    assert {:ok, %{url: @unreachable_url, queue: @queue, backoff: backoff, conn: nil, chan: nil}} =
             ChannelLifecycleConsumer.init(url: @unreachable_url)

    assert_received :connect
    assert backoff > 0
  end

  test "handle_info(:connect, ...) backs off and stays disconnected when the broker is unreachable" do
    state = %{url: @unreachable_url, queue: @queue, backoff: 50, conn: nil, chan: nil}

    assert {:noreply, %{conn: nil, chan: nil, backoff: 100}} =
             ChannelLifecycleConsumer.handle_info(:connect, state)

    assert_receive :connect, 500
  end

  test "handle_info({:DOWN, ...}) resets state and retries" do
    state = %{
      url: @unreachable_url,
      queue: @queue,
      backoff: 30_000,
      conn: :fake_conn,
      chan: :fake_chan
    }

    assert {:noreply, %{conn: nil, chan: nil, backoff: backoff}} =
             ChannelLifecycleConsumer.handle_info(
               {:DOWN, make_ref(), :process, self(), :shutdown},
               state
             )

    assert backoff < 30_000
    assert_received :connect
  end

  test "handle_info({:basic_consume_ok, ...}) is a no-op" do
    state = %{url: @unreachable_url, queue: @queue, backoff: 1_000, conn: nil, chan: nil}

    assert {:noreply, ^state} =
             ChannelLifecycleConsumer.handle_info({:basic_consume_ok, %{}}, state)
  end

  test "handle_info({:basic_cancel, ...}) stops the GenServer" do
    state = %{url: @unreachable_url, queue: @queue, backoff: 1_000, conn: nil, chan: nil}

    assert {:stop, :normal, ^state} =
             ChannelLifecycleConsumer.handle_info({:basic_cancel, %{}}, state)
  end

  test "handle_info({:basic_cancel_ok, ...}) is a no-op" do
    state = %{url: @unreachable_url, queue: @queue, backoff: 1_000, conn: nil, chan: nil}

    assert {:noreply, ^state} =
             ChannelLifecycleConsumer.handle_info({:basic_cancel_ok, %{}}, state)
  end
end
