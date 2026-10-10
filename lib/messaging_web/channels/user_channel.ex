defmodule MessagingWeb.UserChannel do
  use Phoenix.Channel
  require Logger

  alias Messaging.Chat
  alias Messaging.Chat.{ChannelCache, Message}
  alias Messaging.Events.Broadcaster
  alias Messaging.Log
  alias MessagingWeb.ApiError

  @impl true
  def join("user:" <> user_id, _params, %{assigns: %{user_id: user_id}} = socket),
    do: {:ok, socket}

  def join("user:" <> _other, _params, _socket), do: {:error, ApiError.payload(:forbidden)}

  @impl true
  def handle_in("send_dm", %{"to" => recipient_id, "content" => content}, socket)
      when is_binary(content) do
    params = %{
      sender_id: socket.assigns.user_id,
      recipient_id: recipient_id,
      content: content
    }

    case Chat.send_direct_message(params) do
      {:ok, channel, message} ->
        publish_direct(channel, message)

        {:reply,
         {:ok, %{"conversation_id" => channel.channel_id, "message" => Message.to_api(message)}},
         socket}

      {:error, reason} ->
        {:reply, {:error, ApiError.payload(reason)}, socket}
    end
  end

  def handle_in("send_dm", _payload, socket) do
    {:reply, {:error, ApiError.payload(:invalid_payload)}, socket}
  end

  defp publish_direct(%ChannelCache{} = channel, %Message{} = message) do
    payload = Message.to_api(message)

    broadcast("channel:" <> channel.channel_id, "new_message", payload, message.id)

    for user_id <- channel.participants do
      notification = %{
        "conversation_id" => channel.channel_id,
        "partner_id" => Enum.find(channel.participants, &(&1 != user_id)),
        "message" => payload
      }

      broadcast("user:" <> user_id, "new_dm", notification, message.id)
    end

    :ok
  end

  defp broadcast(topic, event, payload, message_id) do
    case Broadcaster.publish_to(topic, event, payload) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("dm_broadcast_failed",
          broadcast_event: event,
          message_id: message_id,
          reason: Log.reason(reason)
        )
    end
  end
end
