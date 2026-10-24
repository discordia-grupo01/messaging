defmodule MessagingWeb.UserChannel do
  use Phoenix.Channel
  require Logger

  alias Messaging.Chat
  alias Messaging.Chat.Message
  alias Messaging.Log
  alias Messaging.Presence
  alias Messaging.Presence.{Status, Tracker}
  alias Messaging.Suspension
  alias MessagingWeb.ApiError
  alias MessagingWeb.MessagePayload

  @impl true
  def join("user:" <> user_id, _params, %{assigns: %{user_id: user_id}} = socket) do
    case Suspension.ensure_active(user_id) do
      :ok -> track(socket)
      {:error, reason} -> {:error, ApiError.payload(reason)}
    end
  end

  def join("user:" <> _other, _params, _socket), do: {:error, ApiError.payload(:forbidden)}

  defp track(socket) do
    user_id = socket.assigns.user_id

    {status, socket} =
      case Tracker.track(self(), user_id) do
        {:ok, %{conn_id: conn_id, status: status}} ->
          {status, assign(socket, :conn_id, conn_id)}

        :untracked ->
          {Status.default_choice(), socket}

        {:error, reason} ->
          Logger.error("presence_track_failed", user_id: user_id, reason: Log.reason(reason))
          {Status.default_choice(), socket}
      end

    {:ok, %{"status" => status, "idle_after_ms" => Presence.idle_after_ms()}, socket}
  end

  @impl true
  def handle_in(event, payload, socket) do
    case Suspension.ensure_active(socket.assigns.user_id) do
      :ok -> dispatch(event, payload, socket)
      {:error, reason} -> {:reply, {:error, ApiError.payload(reason)}, socket}
    end
  end

  defp dispatch("send_dm", %{"to" => recipient_id} = payload, socket) do
    with {:ok, content} <- MessagePayload.content(payload),
         {:ok, client_id} <- MessagePayload.client_id(payload) do
      send_direct(socket, recipient_id, content, Map.get(payload, "attachment_ids"), client_id)
    else
      :error -> {:reply, {:error, ApiError.payload(:invalid_payload)}, socket}
    end
  end

  defp dispatch("send_dm", _payload, socket) do
    {:reply, {:error, ApiError.payload(:invalid_payload)}, socket}
  end

  defp dispatch("set_status", %{"status" => choice}, socket) do
    case Presence.set_manual(socket.assigns.user_id, choice) do
      :ok -> {:reply, {:ok, %{"status" => choice}}, socket}
      {:error, :invalid_status} -> {:reply, {:error, ApiError.payload(:invalid_status)}, socket}
      {:error, _reason} -> {:reply, {:error, ApiError.payload(:presence_unavailable)}, socket}
    end
  end

  defp dispatch("activity", %{"state" => state}, socket) when state in ["active", "idle"] do
    case report_activity(socket, state == "idle") do
      :ok -> {:reply, :ok, socket}
      {:error, _reason} -> {:reply, {:error, ApiError.payload(:presence_unavailable)}, socket}
    end
  end

  defp dispatch(_event, _payload, socket) do
    {:reply, {:error, ApiError.payload(:invalid_payload)}, socket}
  end

  defp report_activity(%{assigns: %{conn_id: conn_id, user_id: user_id}}, idle),
    do: Presence.set_activity(user_id, conn_id, idle)

  defp report_activity(_socket, _idle), do: :ok

  defp send_direct(socket, recipient_id, content, attachment_ids, client_id) do
    params = %{
      sender_id: socket.assigns.user_id,
      recipient_id: recipient_id,
      content: content,
      attachment_ids: attachment_ids,
      client_id: client_id
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
