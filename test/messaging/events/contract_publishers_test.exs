defmodule Messaging.Events.ContractPublishersTest do
  use ExUnit.Case, async: true

  alias Discordia.EventsContract.Validator
  alias Messaging.Chat.Message
  alias Messaging.Events.DomainEvent

  @event_id "7c1d2e3f-4a5b-4c6d-8e9f-0a1b2c3d4e5f"
  @server_id "0b6f1c8e-7a2d-4e3f-9c1b-5d4a3e2f1a0b"
  @channel_id "6d5c4b3a-2e1f-4a0b-9c8d-7e6f5a4b3c2d"
  @message_id "01a1b2c3-d4e5-7f60-8a9b-0c1d2e3f4a5b"
  @author_id "3f2e1d0c-9b8a-4766-b554-433221100ffe"
  @mentioned_id "8a7b6c5d-4e3f-4a2b-9c1d-0e9f8a7b6c5d"

  defp message do
    %Message{
      id: @message_id,
      channel_id: @channel_id,
      server_id: @server_id,
      user_id: @author_id,
      content: "hola",
      inserted_at: ~U[2026-11-10 15:00:00.123Z]
    }
  end

  defp domain(entry), do: Map.put(entry.payload, "event_id", @event_id)

  test "message_created publishes what the contract says" do
    entry = DomainEvent.message_created(message(), [@mentioned_id], "general")
    assert Validator.validate(entry.event, domain(entry)) == :ok
  end

  test "message_updated publishes what the contract says" do
    edited = %{message() | edited_at: ~U[2026-11-10 15:30:00Z]}
    entry = DomainEvent.message_updated(edited, [@mentioned_id], "general")
    assert Validator.validate(entry.event, domain(entry)) == :ok
  end

  test "message_deleted publishes what the contract says" do
    entry = DomainEvent.message_deleted(message(), ~U[2026-11-10 16:00:00Z])
    assert Validator.validate(entry.event, domain(entry)) == :ok
  end

  test "direct_message_created publishes what the contract says" do
    dm = %{message() | server_id: nil, channel_id: "conv-1"}
    entry = DomainEvent.direct_message_created(dm, @mentioned_id)
    assert Validator.validate(entry.event, domain(entry)) == :ok
  end

  test "user_presence_changed publishes what the contract says" do
    entry = DomainEvent.user_presence_changed(@author_id, :active, false, 3)
    assert Validator.validate(entry.event, domain(entry)) == :ok
  end

  defp broadcast(event, topic, payload),
    do: %{"event_id" => @event_id, "topic" => topic, "event" => event, "payload" => payload}

  test "the message JSON clients receive matches the broadcast contract" do
    assert Validator.validate(
             "broadcast.new_message",
             broadcast("new_message", "channel:" <> @channel_id, Message.to_api(message()))
           ) == :ok

    assert Validator.validate(
             "broadcast.message_updated",
             broadcast("message_updated", "channel:" <> @channel_id, Message.to_api(message()))
           ) == :ok
  end

  test "the deletion and reaction JSON match the broadcast contract" do
    deleted = Message.to_deleted_api(%{message() | deleted_at: ~U[2026-11-10 16:00:00Z]})

    assert Validator.validate(
             "broadcast.message_deleted",
             broadcast("message_deleted", "channel:" <> @channel_id, deleted)
           ) == :ok

    reaction =
      Message.reaction_api(%{message: message(), emoji: "👍", count: 2}, @author_id, "add")

    assert Validator.validate(
             "broadcast.reaction_updated",
             broadcast("reaction_updated", "channel:" <> @channel_id, reaction)
           ) == :ok
  end
end
