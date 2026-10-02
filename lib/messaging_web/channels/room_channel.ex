defmodule MessagingWeb.RoomChannel do
  use Phoenix.Channel
  require Logger

  alias Messaging.Chat
  alias Messaging.Chat.Message
  alias MessagingWeb.ApiError

  @dialyzer {:nowarn_function, handle_info: 2}

  @impl true
  def join("channel:" <> channel_id, params, socket) do
    user_id = socket.assigns.user_id
    raw_jwt = socket.assigns.raw_jwt

    with {:ok, channel} <- Chat.channel_exists?(channel_id),
         {:ok, true} <- Chat.can_send_messages?(channel, user_id, raw_jwt) do
      socket = assign(socket, channel_id: channel_id)
      send(self(), {:after_join, Map.get(params, "since")})
      Logger.info("messaging: channel_joined channel_id=#{channel_id} user_id=#{user_id}")
      {:ok, socket}
    else
      {:ok, false} ->
        {:error, ApiError.payload(:forbidden)}

      {:error, reason} ->
        {:error, ApiError.payload(reason)}
    end
  end

  @impl true
  def handle_info({:after_join, since}, socket) do
    push_missed_messages(socket, since)
    {:noreply, socket}
  end

  @impl true
  def handle_in("new_message", %{"content" => content}, socket) do
    params = %{
      channel_id: socket.assigns.channel_id,
      user_id: socket.assigns.user_id,
      content: content,
      raw_jwt: socket.assigns.raw_jwt
    }

    case Chat.send_message(params) do
      {:ok, message} ->
        :ok = broadcaster().publish(Message.to_api(message))
        {:reply, :ok, socket}

      {:error, reason} ->
        {:reply, {:error, ApiError.payload(reason)}, socket}
    end
  end

  defp push_missed_messages(_socket, nil), do: :ok

  defp push_missed_messages(socket, since) do
    with {:ok, since_dt, _offset} <- DateTime.from_iso8601(since),
         {:ok, messages} <- Chat.messages_since(socket.assigns.channel_id, since_dt) do
      push(socket, "missed_messages", %{"messages" => Enum.map(messages, &Message.to_api/1)})
    else
      _error -> :ok
    end
  end

  defp broadcaster,
    do: Application.get_env(:messaging, :broadcaster, Messaging.Events.BroadcastPublisher)
end
