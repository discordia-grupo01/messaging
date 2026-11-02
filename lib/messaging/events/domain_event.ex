defmodule Messaging.Events.DomainEvent do
  alias Messaging.Chat.Message

  @topic "domain"
  @routing_key_message_created "messaging.message_created"
  @routing_key_direct_message_created "messaging.direct_message_created"

  @spec topic() :: String.t()
  def topic, do: @topic

  @spec routing_key_message_created() :: String.t()
  def routing_key_message_created, do: @routing_key_message_created

  @spec routing_key_direct_message_created() :: String.t()
  def routing_key_direct_message_created, do: @routing_key_direct_message_created

  @spec message_created(Message.t(), [String.t()]) :: map()
  def message_created(%Message{} = message, mentioned_user_ids) do
    %{
      event: @routing_key_message_created,
      topic: @topic,
      payload: %{
        "occurred_at" => DateTime.to_iso8601(message.inserted_at),
        "server_id" => message.server_id,
        "channel_id" => message.channel_id,
        "message_id" => message.id,
        "author_id" => message.user_id,
        "mentioned_user_ids" => mentioned_user_ids
      },
      message_id: message.id,
      channel_id: message.channel_id
    }
  end

  @spec direct_message_created(Message.t(), String.t()) :: map()
  def direct_message_created(%Message{} = message, recipient_id) do
    %{
      event: @routing_key_direct_message_created,
      topic: @topic,
      payload: %{
        "occurred_at" => DateTime.to_iso8601(message.inserted_at),
        "conversation_id" => message.channel_id,
        "message_id" => message.id,
        "author_id" => message.user_id,
        "recipient_id" => recipient_id
      },
      message_id: message.id,
      channel_id: message.channel_id
    }
  end
end
