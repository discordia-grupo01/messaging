defmodule Messaging.Events.ServerBoostsConsumerUnitTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Mox

  alias Messaging.Events.ServerBoostsConsumer

  @unreachable_url "amqp://guest:guest@127.0.0.1:1/"
  @updated "servers.server_boost_updated"

  setup :set_mox_from_context
  setup :verify_on_exit!

  defp payload(overrides \\ %{}) do
    %{
      "event_id" => Messaging.UUID.generate(),
      "occurred_at" => "2026-11-05T12:00:00Z",
      "server_id" => "server-1",
      "boost_count" => 15,
      "level" => 2,
      "version" => 7
    }
    |> Map.merge(overrides)
    |> Jason.encode!()
  end

  defp state(overrides \\ []) do
    Map.merge(
      %{url: @unreachable_url, queue: "q", backoff: 50, conn: nil, chan: nil},
      Map.new(overrides)
    )
  end

  test "init/1 starts disconnected on its own queue" do
    assert {:ok, %{queue: "messaging.server_boosts", conn: nil}} =
             ServerBoostsConsumer.init(url: @unreachable_url)

    assert_received :connect
  end

  test "backs off when the broker is unreachable" do
    capture_log(fn ->
      assert {:noreply, %{conn: nil, backoff: 100}} =
               ServerBoostsConsumer.handle_info(:connect, state())
    end)

    assert_receive :connect, 500
  end

  test "reconnects when the connection goes down" do
    capture_log(fn ->
      assert {:noreply, %{conn: nil, chan: nil}} =
               ServerBoostsConsumer.handle_info(
                 {:DOWN, make_ref(), :process, self(), :shutdown},
                 state(conn: :fake, chan: :fake)
               )
    end)

    assert_received :connect
  end

  test "ignores the consumer lifecycle messages" do
    state = state()
    assert {:noreply, ^state} = ServerBoostsConsumer.handle_info({:basic_consume_ok, %{}}, state)
    assert {:noreply, ^state} = ServerBoostsConsumer.handle_info({:basic_cancel_ok, %{}}, state)

    assert {:stop, :normal, ^state} =
             ServerBoostsConsumer.handle_info({:basic_cancel, %{}}, state)
  end

  test "terminate/2 without a connection does nothing" do
    assert :ok = ServerBoostsConsumer.terminate(:normal, state())
  end

  describe "process/2" do
    test "stores the level with its version" do
      expect(Messaging.Chat.RepoMock, :apply_server_boost, fn "server-1", 2, 7 ->
        {:ok, :applied}
      end)

      assert :ack = ServerBoostsConsumer.process(payload(), @updated)
    end

    test "an old version is not an error" do
      expect(Messaging.Chat.RepoMock, :apply_server_boost, fn _id, _level, _version ->
        {:ok, :stale}
      end)

      assert :ack = ServerBoostsConsumer.process(payload(), @updated)
    end

    test "a failure in Mongo asks for the delivery to be requeued" do
      expect(Messaging.Chat.RepoMock, :apply_server_boost, fn _id, _level, _version ->
        {:error, :down}
      end)

      assert capture_log(fn ->
               assert :retry = ServerBoostsConsumer.process(payload(), @updated)
             end) =~ "server_boosts_consumer_event_failed"
    end

    test "discards what it can't use without touching the state" do
      for {body, key} <- [
            {payload(), "servers.something_else"},
            {payload(%{"server_id" => ""}), @updated},
            {payload(%{"level" => 4}), @updated},
            {payload(%{"level" => "2"}), @updated},
            {payload(%{"version" => 0}), @updated},
            {Jason.encode!(%{"event_id" => "x"}), @updated},
            {Jason.encode!([1, 2]), @updated},
            {"not json", @updated}
          ] do
        capture_log(fn -> assert :ack = ServerBoostsConsumer.process(body, key) end)
      end
    end
  end
end
