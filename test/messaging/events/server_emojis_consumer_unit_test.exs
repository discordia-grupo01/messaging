defmodule Messaging.Events.ServerEmojisConsumerUnitTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Mox

  alias Messaging.Events.ServerEmojisConsumer

  @unreachable_url "amqp://guest:guest@127.0.0.1:1/"
  @created "servers.emoji_created"
  @deleted "servers.emoji_deleted"

  setup :set_mox_from_context
  setup :verify_on_exit!

  defp payload(overrides \\ %{}) do
    %{
      "event_id" => Messaging.UUID.generate(),
      "occurred_at" => "2026-11-05T12:00:00Z",
      "emoji_id" => "emoji-1",
      "server_id" => "server-1",
      "name" => "party",
      "animated" => true,
      "image_url" => "https://cdn.test/party.gif"
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
    assert {:ok, %{queue: "messaging.server_emojis", conn: nil}} =
             ServerEmojisConsumer.init(url: @unreachable_url)

    assert_received :connect
  end

  test "backs off when the broker is unreachable" do
    capture_log(fn ->
      assert {:noreply, %{conn: nil, backoff: 100}} =
               ServerEmojisConsumer.handle_info(:connect, state())
    end)

    assert_receive :connect, 500
  end

  test "reconnects when the connection goes down" do
    capture_log(fn ->
      assert {:noreply, %{conn: nil, chan: nil}} =
               ServerEmojisConsumer.handle_info(
                 {:DOWN, make_ref(), :process, self(), :shutdown},
                 state(conn: :fake, chan: :fake)
               )
    end)

    assert_received :connect
  end

  test "ignores the consumer lifecycle messages" do
    state = state()
    assert {:noreply, ^state} = ServerEmojisConsumer.handle_info({:basic_consume_ok, %{}}, state)
    assert {:noreply, ^state} = ServerEmojisConsumer.handle_info({:basic_cancel_ok, %{}}, state)

    assert {:stop, :normal, ^state} =
             ServerEmojisConsumer.handle_info({:basic_cancel, %{}}, state)
  end

  test "terminate/2 without a connection does nothing" do
    assert :ok = ServerEmojisConsumer.terminate(:normal, state())
  end

  describe "process/2" do
    test "stores a created emoji" do
      expect(Messaging.Chat.RepoMock, :apply_emoji_created, fn emoji ->
        assert emoji == %{
                 "_id" => "emoji-1",
                 "server_id" => "server-1",
                 "name" => "party",
                 "animated" => true,
                 "image_url" => "https://cdn.test/party.gif"
               }

        :ok
      end)

      assert :ack = ServerEmojisConsumer.process(payload(), @created)
    end

    test "stores a deleted emoji" do
      expect(Messaging.Chat.RepoMock, :apply_emoji_deleted, fn %{"_id" => "emoji-1"} -> :ok end)

      assert :ack = ServerEmojisConsumer.process(payload(), @deleted)
    end

    test "a failure in Mongo asks for the delivery to be requeued" do
      expect(Messaging.Chat.RepoMock, :apply_emoji_created, fn _emoji -> {:error, :down} end)

      assert capture_log(fn ->
               assert :retry = ServerEmojisConsumer.process(payload(), @created)
             end) =~ "server_emojis_consumer_event_failed"
    end

    test "discards what it can't use without touching the replica" do
      for {body, key} <- [
            {payload(), "servers.something_else"},
            {payload(%{"emoji_id" => ""}), @created},
            {payload(%{"animated" => "yes"}), @created},
            {Jason.encode!(%{"event_id" => "x"}), @deleted},
            {Jason.encode!([1, 2]), @created},
            {"not json", @created}
          ] do
        capture_log(fn -> assert :ack = ServerEmojisConsumer.process(body, key) end)
      end
    end
  end
end
