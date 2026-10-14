defmodule Messaging.Outbox.DispatcherTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  import Mox

  alias Messaging.Outbox.Dispatcher

  setup :verify_on_exit!

  defp row(overrides \\ %{}) do
    Map.merge(
      %{
        id: "evt-1",
        event: "new_message",
        topic: "channel:chan-1",
        payload: %{"id" => "msg-1"},
        apply: nil,
        message_id: "msg-1",
        channel_id: "chan-1",
        attempts: 0
      },
      overrides
    )
  end

  test "publishes the event with its id, topic and payload" do
    expect(Messaging.EventPublisherMock, :publish_event, fn "evt-1",
                                                            "channel:chan-1",
                                                            "new_message",
                                                            %{"id" => "msg-1"} ->
      :ok
    end)

    assert :ok = Dispatcher.handle(row())
  end

  test "finishes the write in Mongo first, and publishes after" do
    test_pid = self()

    expect(Messaging.Chat.RepoMock, :upsert_message, fn _doc ->
      send(test_pid, :mongo)
      :ok
    end)

    expect(Messaging.EventPublisherMock, :publish_event, fn _, _, _, _ ->
      assert_received :mongo
      :ok
    end)

    apply = %{"op" => "insert_message", "doc" => %{"_id" => "msg-1"}}

    assert :ok = Dispatcher.handle(row(%{apply: apply}))
  end

  test "nothing is published if Mongo could not be completed, and it is retried without counting" do
    expect(Messaging.Chat.RepoMock, :upsert_message, fn _doc -> {:error, :timeout} end)

    apply = %{"op" => "insert_message", "doc" => %{"_id" => "msg-1"}}

    capture_log(fn ->
      assert {:retry, :timeout} = Dispatcher.handle(row(%{apply: apply}))
    end)
  end

  test "a broker that is down or does not confirm is a retry, not a failed attempt" do
    for reason <- [:not_connected, :not_confirmed, :confirm_timeout] do
      expect(Messaging.EventPublisherMock, :publish_event, fn _, _, _, _ -> {:error, reason} end)

      capture_log(fn -> assert {:retry, ^reason} = Dispatcher.handle(row()) end)
    end
  end

  test "a row nobody can make sense of is a failed attempt" do
    capture_log(fn ->
      assert {:error, {:invalid, {:unknown_apply, "teleport"}}} =
               Dispatcher.handle(row(%{apply: %{"op" => "teleport"}}))
    end)
  end

  test "a batch stops trying once the broker is down, and leaves the rest untouched" do
    expect(Messaging.EventPublisherMock, :publish_event, 1, fn "evt-1", _, _, _ ->
      {:error, :not_connected}
    end)

    rows = [row(%{id: "evt-1"}), row(%{id: "evt-2"}), row(%{id: "evt-3"})]

    capture_log(fn ->
      assert [
               {"evt-1", {:retry, :not_connected}},
               {"evt-2", {:retry, :not_connected}},
               {"evt-3", {:retry, :not_connected}}
             ] = Dispatcher.handle_batch(rows)
    end)
  end

  test "an invalid row does not stop the rest of the batch" do
    expect(Messaging.EventPublisherMock, :publish_event, 1, fn "evt-2", _, _, _ -> :ok end)

    rows = [row(%{id: "evt-1", apply: %{"op" => "teleport"}}), row(%{id: "evt-2"})]

    capture_log(fn ->
      assert [{"evt-1", {:error, {:invalid, _}}}, {"evt-2", :ok}] = Dispatcher.handle_batch(rows)
    end)
  end
end
