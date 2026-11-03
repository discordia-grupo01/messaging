defmodule Messaging.Events.DomainEvent do
  alias Messaging.Chat.Message
  alias Messaging.Events.Preview

  @topic "domain"
  @routing_key_message_created "messaging.message_created"
  @routing_key_direct_message_created "messaging.direct_message_created"
  @routing_key_message_updated "messaging.message_updated"
  @routing_key_message_deleted "messaging.message_deleted"
  @routing_key_user_presence_changed "messaging.user_presence_changed"

  @spec topic() :: String.t()
  def topic, do: @topic

  @spec routing_key_message_created() :: String.t()
  def routing_key_message_created, do: @routing_key_message_created

  @spec routing_key_direct_message_created() :: String.t()
  def routing_key_direct_message_created, do: @routing_key_direct_message_created

  @spec routing_key_message_updated() :: String.t()
  def routing_key_message_updated, do: @routing_key_message_updated

  @spec routing_key_message_deleted() :: String.t()
  def routing_key_message_deleted, do: @routing_key_message_deleted

  @spec routing_key_user_presence_changed() :: String.t()
  def routing_key_user_presence_changed, do: @routing_key_user_presence_changed

  @spec message_created(Message.t(), [String.t()], String.t() | nil) :: map()
  def message_created(%Message{} = message, mentioned_user_ids, channel_name) do
    %{
      event: @routing_key_message_created,
      topic: @topic,
      payload:
        %{
          "occurred_at" => DateTime.to_iso8601(message.inserted_at),
          "server_id" => message.server_id,
          "channel_id" => message.channel_id,
          "message_id" => message.id,
          "author_id" => message.user_id,
          "mentioned_user_ids" => mentioned_user_ids
        }
        |> put_present("channel_name", channel_name)
        |> put_present("content_preview", Preview.of(message)),
      message_id: message.id,
      channel_id: message.channel_id
    }
  end

  @spec direct_message_created(Message.t(), String.t()) :: map()
  def direct_message_created(%Message{} = message, recipient_id) do
    %{
      event: @routing_key_direct_message_created,
      topic: @topic,
      payload:
        %{
          "occurred_at" => DateTime.to_iso8601(message.inserted_at),
          "conversation_id" => message.channel_id,
          "message_id" => message.id,
          "author_id" => message.user_id,
          "recipient_id" => recipient_id
        }
        |> put_present("content_preview", Preview.of(message)),
      message_id: message.id,
      channel_id: message.channel_id
    }
  end

  @spec message_updated(Message.t(), [String.t()], String.t() | nil) :: map()
  def message_updated(%Message{} = message, mentioned_user_ids, channel_name) do
    %{
      event: @routing_key_message_updated,
      topic: @topic,
      payload:
        %{
          "occurred_at" => DateTime.to_iso8601(message.edited_at),
          "server_id" => message.server_id,
          "channel_id" => message.channel_id,
          "message_id" => message.id,
          "author_id" => message.user_id,
          "mentioned_user_ids" => mentioned_user_ids
        }
        |> put_present("channel_name", channel_name)
        |> put_present("content_preview", Preview.of(message)),
      message_id: message.id,
      channel_id: message.channel_id
    }
  end

  @spec message_deleted(Message.t(), DateTime.t()) :: map()
  def message_deleted(%Message{} = message, %DateTime{} = deleted_at) do
    %{
      event: @routing_key_message_deleted,
      topic: @topic,
      payload:
        %{
          "occurred_at" => DateTime.to_iso8601(deleted_at),
          "channel_id" => message.channel_id,
          "message_id" => message.id,
          "author_id" => message.user_id
        }
        |> put_present("server_id", message.server_id),
      message_id: message.id,
      channel_id: message.channel_id
    }
  end

  @spec user_presence_changed(String.t(), String.t(), boolean(), non_neg_integer()) :: map()
  def user_presence_changed(user_id, connections, do_not_disturb, version) do
    %{
      event: @routing_key_user_presence_changed,
      topic: @topic,
      payload: %{
        "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "user_id" => user_id,
        "connections" => connections,
        "do_not_disturb" => do_not_disturb,
        "version" => version
      }
    }
  end

  defp put_present(payload, _key, nil), do: payload
  defp put_present(payload, _key, ""), do: payload
  defp put_present(payload, key, value), do: Map.put(payload, key, value)
end
