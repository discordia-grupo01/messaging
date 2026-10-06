mongo_url = System.get_env("MONGO_URL")

if mongo_url do
  defmodule Messaging.Events.MemberLeftDeliveryTest do
    use ExUnit.Case, async: false
    import Mox

    alias Messaging.Events.ChannelLifecycleConsumer

    setup :set_mox_global
    setup :verify_on_exit!

    test "a member_left delivery deletes the member's mentions and is audited as processed" do
      event_id = Messaging.UUID.generate()

      expect(Messaging.Chat.RepoMock, :delete_member_mentions, fn "srv-1", "user-1" -> :ok end)

      body =
        Jason.encode!(%{
          "event_id" => event_id,
          "occurred_at" => "2026-10-06T12:00:00Z",
          "server_id" => "srv-1",
          "user_id" => "user-1"
        })

      # ack is a cast to the channel process: pointing it at ourselves is harmless.
      chan = %AMQP.Channel{pid: self()}
      state = %{url: "amqp://unused", queue: "q", backoff: 1_000, conn: nil, chan: chan}
      meta = %{routing_key: "servers.member_left", delivery_tag: 1}

      assert {:noreply, ^state} =
               ChannelLifecycleConsumer.handle_info({:basic_deliver, body, meta}, state)

      assert %{"status" => "processed", "routing_key" => "servers.member_left"} =
               Mongo.find_one(Messaging.Mongo, "consumed_events", %{"_id" => event_id})
    end
  end
end
