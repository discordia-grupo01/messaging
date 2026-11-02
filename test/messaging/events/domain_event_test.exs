defmodule Messaging.Events.DomainEventTest do
  use ExUnit.Case, async: true

  alias Messaging.Chat.Message
  alias Messaging.Events.DomainEvent

  defp message(overrides \\ %{}) do
    struct!(
      %Message{
        id: "01a16a21-7df1-7001-8e37-5a0fdc09d1cd",
        channel_id: "chan-1",
        server_id: "srv-1",
        user_id: "user-1",
        content: "texto privado",
        inserted_at: ~U[2026-10-24 15:00:00.123Z]
      },
      overrides
    )
  end

  test "exposes the topic and the routing key the publisher and the contract agree on" do
    assert DomainEvent.topic() == "domain"
    assert DomainEvent.routing_key_message_created() == "messaging.message_created"

    assert DomainEvent.routing_key_direct_message_created() ==
             "messaging.direct_message_created"
  end

  test "message_created/2 builds an outbox entry that is ordered with the message's other events" do
    entry = DomainEvent.message_created(message(), ["user-2"])

    assert entry.event == "messaging.message_created"
    assert entry.topic == "domain"
    assert entry.message_id == "01a16a21-7df1-7001-8e37-5a0fdc09d1cd"
    assert entry.channel_id == "chan-1"
    refute Map.has_key?(entry, :apply)
  end

  test "message_created/2 carries ids and the time, and nothing the message says" do
    assert %{payload: payload} = DomainEvent.message_created(message(), ["user-2", "user-3"])

    assert payload == %{
             "occurred_at" => "2026-10-24T15:00:00.123Z",
             "server_id" => "srv-1",
             "channel_id" => "chan-1",
             "message_id" => "01a16a21-7df1-7001-8e37-5a0fdc09d1cd",
             "author_id" => "user-1",
             "mentioned_user_ids" => ["user-2", "user-3"]
           }

    refute inspect(payload) =~ "texto privado"
  end

  test "message_created/2 keeps an empty list when nobody is mentioned" do
    assert %{payload: %{"mentioned_user_ids" => []}} = DomainEvent.message_created(message(), [])
  end

  test "the payload encodes to JSON as the contract expects" do
    %{payload: payload} = DomainEvent.message_created(message(), ["user-2"])

    assert {:ok, json} = Jason.encode(payload)
    assert %{"mentioned_user_ids" => ["user-2"]} = Jason.decode!(json)
  end

  describe "direct_message_created/2" do
    defp direct_message, do: message(%{server_id: nil, channel_id: "conversation-1"})

    test "builds an outbox entry on the domain topic, ordered with the message's other events" do
      entry = DomainEvent.direct_message_created(direct_message(), "user-2")

      assert entry.event == "messaging.direct_message_created"
      assert entry.topic == "domain"
      assert entry.message_id == "01a16a21-7df1-7001-8e37-5a0fdc09d1cd"
      assert entry.channel_id == "conversation-1"
      refute Map.has_key?(entry, :apply)
    end

    test "carries ids and the time, and nothing the message says" do
      assert %{payload: payload} = DomainEvent.direct_message_created(direct_message(), "user-2")

      assert payload == %{
               "occurred_at" => "2026-10-24T15:00:00.123Z",
               "conversation_id" => "conversation-1",
               "message_id" => "01a16a21-7df1-7001-8e37-5a0fdc09d1cd",
               "author_id" => "user-1",
               "recipient_id" => "user-2"
             }

      refute inspect(payload) =~ "texto privado"
      assert {:ok, _json} = Jason.encode(payload)
    end
  end
end
