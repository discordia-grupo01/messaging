defmodule Messaging.Outbox.BroadcasterTest do
  use ExUnit.Case, async: true
  import Mox

  alias Messaging.Outbox.Broadcaster

  setup :verify_on_exit!

  test "an event becomes one row, keyed by the message it is about" do
    expect(Messaging.Outbox.StoreMock, :insert, fn [row] ->
      assert row.event == "reaction_updated"
      assert row.topic == "channel:chan-1"
      assert row.message_id == "msg-1"
      assert row.channel_id == "chan-1"
      assert row.payload == %{"channel_id" => "chan-1", "message_id" => "msg-1"}
      :ok
    end)

    assert :ok =
             Broadcaster.publish("channel:chan-1", "reaction_updated", %{
               "channel_id" => "chan-1",
               "message_id" => "msg-1"
             })
  end

  test "the message an event is about is found in any of the shapes it comes in" do
    expect(Messaging.Outbox.StoreMock, :insert, fn rows ->
      assert Enum.map(rows, & &1.message_id) == ["m1", "m2", "m3", nil]
      :ok
    end)

    assert :ok =
             Broadcaster.publish_many([
               {"channel:c", "message_updated", %{"id" => "m1", "channel_id" => "c"}},
               {"channel:c", "reaction_updated", %{"message_id" => "m2"}},
               {"user:u", "mention", %{"message" => %{"id" => "m3"}}},
               {"channel:c", "access_revoked", %{"reason" => "x"}}
             ])
  end

  test "many events go in a single call to the store" do
    expect(Messaging.Outbox.StoreMock, :insert, 1, fn rows ->
      assert length(rows) == 3
      :ok
    end)

    events = for n <- 1..3, do: {"user:u#{n}", "mention", %{"message" => %{"id" => "m"}}}

    assert :ok = Broadcaster.publish_many(events)
  end

  test "a store that fails is an error the caller can see" do
    expect(Messaging.Outbox.StoreMock, :insert, fn _rows -> {:error, :timeout} end)

    assert {:error, :timeout} = Broadcaster.publish("user:u", "mention", %{})
  end
end
