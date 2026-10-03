defmodule MessagingWeb.RoomChannel do
  use Phoenix.Channel
  require Logger

  alias Messaging.Chat
  alias Messaging.Chat.Message
  alias Messaging.Events.Broadcaster
  alias MessagingWeb.ApiError

  @dialyzer {:nowarn_function, handle_info: 2}

  @impl true
  def join("channel:" <> channel_id, params, socket) do
    user_id = socket.assigns.user_id
    raw_jwt = socket.assigns.raw_jwt
    last_message_id = Map.get(params, "last_message_id")

    with :ok <- validate_cursor(last_message_id),
         {:ok, channel} <- Chat.channel_exists?(channel_id),
         {:ok, true} <- Chat.can_view_channel?(channel, user_id, raw_jwt) do
      socket = assign(socket, channel_id: channel_id)
      send(self(), {:after_join, last_message_id})
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
  def handle_info({:after_join, last_message_id}, socket) do
    case push_missed_messages(socket, last_message_id) do
      :ok ->
        {:noreply, socket}

      {:error, reason} ->
        Logger.warning(
          "messaging: catch_up_failed channel_id=#{socket.assigns.channel_id} reason=#{inspect(reason)}"
        )

        {:stop, :catch_up_failed, socket}
    end
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
        :ok = Broadcaster.publish("new_message", Message.to_api(message))
        {:reply, :ok, socket}

      {:error, reason} ->
        {:reply, {:error, ApiError.payload(reason)}, socket}
    end
  end

  defp validate_cursor(nil), do: :ok
  defp validate_cursor(id) when is_binary(id), do: :ok
  defp validate_cursor(_other), do: {:error, :invalid_cursor}

  defp push_missed_messages(_socket, nil), do: :ok

  defp push_missed_messages(socket, last_message_id) do
    case Chat.list_messages(socket.assigns.channel_id,
           after: last_message_id,
           limit: Chat.max_page_limit()
         ) do
      {:ok, messages, next_cursor} ->
        push(socket, "missed_messages", %{
          "messages" => Enum.map(messages, &Message.to_api/1),
          "next_cursor" => next_cursor
        })

        :ok

      {:error, :invalid_cursor} ->
        push(socket, "resync_required", %{})
        :ok

      {:error, _reason} = error ->
        error
    end
  end
end
