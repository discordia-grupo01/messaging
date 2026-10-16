defmodule MessagingWeb.UserChannel do
  use Phoenix.Channel
  require Logger

  alias Messaging.Chat
  alias Messaging.Chat.Message
  alias Messaging.Suspension
  alias MessagingWeb.ApiError
  alias MessagingWeb.MessagePayload

  @impl true
  def join("user:" <> user_id, _params, %{assigns: %{user_id: user_id}} = socket) do
    case Suspension.ensure_active(user_id) do
      :ok -> {:ok, socket}
      {:error, reason} -> {:error, ApiError.payload(reason)}
    end
  end

  def join("user:" <> _other, _params, _socket), do: {:error, ApiError.payload(:forbidden)}

  @impl true
  def handle_in(event, payload, socket) do
    case Suspension.ensure_active(socket.assigns.user_id) do
      :ok -> dispatch(event, payload, socket)
      {:error, reason} -> {:reply, {:error, ApiError.payload(reason)}, socket}
    end
  end

  defp dispatch("send_dm", %{"to" => recipient_id} = payload, socket) do
    case MessagePayload.content(payload) do
      {:ok, content} ->
        send_direct(socket, recipient_id, content, Map.get(payload, "attachment_ids"))

      :error ->
        {:reply, {:error, ApiError.payload(:invalid_payload)}, socket}
    end
  end

  defp dispatch("send_dm", _payload, socket) do
    {:reply, {:error, ApiError.payload(:invalid_payload)}, socket}
  end

  defp send_direct(socket, recipient_id, content, attachment_ids) do
    params = %{
      sender_id: socket.assigns.user_id,
      recipient_id: recipient_id,
      content: content,
      attachment_ids: attachment_ids
    }

    case Chat.send_direct_message(params) do
      {:ok, channel, message} ->
        {:reply,
         {:ok, %{"conversation_id" => channel.channel_id, "message" => Message.to_api(message)}},
         socket}

      {:error, reason} ->
        {:reply, {:error, ApiError.payload(reason)}, socket}
    end
  end
end
