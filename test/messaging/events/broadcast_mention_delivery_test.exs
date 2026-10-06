defmodule Messaging.Events.BroadcastMentionDeliveryTest do
  use ExUnit.Case, async: false

  alias Messaging.Events.BroadcastConsumer
  alias Phoenix.Socket.Broadcast

  defp deliver(body) do
    state = %{url: "amqp://unused", backoff: 1_000, conn: nil, chan: %AMQP.Channel{pid: self()}}

    assert {:noreply, ^state} =
             BroadcastConsumer.handle_info({:basic_deliver, body, %{delivery_tag: 1}}, state)
  end

  test "a mention published by any instance reaches the user's local topic" do
    user_id = "user-#{System.unique_integer([:positive])}"
    MessagingWeb.Endpoint.subscribe("user:" <> user_id)
    payload = %{"server_id" => "srv-1", "channel_id" => "chan-1", "message" => %{"id" => "m1"}}

    deliver(
      Jason.encode!(%{"topic" => "user:" <> user_id, "event" => "mention", "payload" => payload})
    )

    assert_receive %Broadcast{topic: "user:" <> ^user_id, event: "mention", payload: ^payload}
  end

  test "an event it doesn't know is still dropped" do
    user_id = "user-#{System.unique_integer([:positive])}"
    MessagingWeb.Endpoint.subscribe("user:" <> user_id)

    deliver(Jason.encode!(%{"topic" => "user:" <> user_id, "event" => "nope", "payload" => %{}}))

    refute_receive %Broadcast{}, 100
  end
end
