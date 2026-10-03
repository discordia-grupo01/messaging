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
         {:ok, changes_since} <- parse_changes_since(Map.get(params, "changes_since")),
         {:ok, channel} <- Chat.channel_exists?(channel_id),
         {:ok, true} <- Chat.can_view_channel?(channel, user_id, raw_jwt) do
      socket = assign(socket, channel_id: channel_id)
      send(self(), {:after_join, last_message_id, changes_since})
      Logger.info("messaging: channel_joined channel_id=#{channel_id} user_id=#{user_id}")
      {:ok, %{"server_time" => Chat.server_time()}, socket}
    else
      {:ok, false} ->
        {:error, ApiError.payload(:forbidden)}

      {:error, reason} ->
        {:error, ApiError.payload(reason)}
    end
  end

  @impl true
  def handle_info({:after_join, last_message_id, changes_since}, socket) do
    with :ok <- push_missed_messages(socket, last_message_id),
         :ok <- push_changes(socket, changes_since) do
      {:noreply, socket}
    else
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

  def handle_in("edit_message", %{"id" => message_id, "content" => content}, socket) do
    params = %{
      channel_id: socket.assigns.channel_id,
      message_id: message_id,
      user_id: socket.assigns.user_id,
      content: content,
      raw_jwt: socket.assigns.raw_jwt
    }

    case Chat.edit_message(params) do
      {:ok, message, :updated} ->
        publish_update(message)
        {:reply, {:ok, Message.to_api(message)}, socket}

      {:ok, message, :unchanged} ->
        {:reply, {:ok, Message.to_api(message)}, socket}

      {:error, reason} ->
        {:reply, {:error, ApiError.payload(reason)}, socket}
    end
  end

  def handle_in(event, _payload, socket) when event in ["new_message", "edit_message"] do
    {:reply, {:error, ApiError.payload(:invalid_payload)}, socket}
  end

  defp publish_update(message) do
    case Broadcaster.publish("message_updated", Message.to_api(message)) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "messaging: message_updated_broadcast_failed message_id=#{message.id} reason=#{inspect(reason)}"
        )
    end
  end

  defp validate_cursor(nil), do: :ok
  defp validate_cursor(id) when is_binary(id), do: :ok
  defp validate_cursor(_other), do: {:error, :invalid_cursor}

  defp parse_changes_since(nil), do: {:ok, nil}

  defp parse_changes_since(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, :invalid_cursor}
    end
  end

  defp parse_changes_since(_other), do: {:error, :invalid_cursor}

  defp push_changes(_socket, nil), do: :ok

  defp push_changes(socket, since) do
    case Chat.list_changes(socket.assigns.channel_id, since) do
      {:ok, messages} ->
        push(socket, "changed_messages", %{"messages" => Enum.map(messages, &Message.to_api/1)})
        :ok

      {:error, :too_many_changes} ->
        push(socket, "resync_required", %{})
        :ok

      {:error, _reason} = error ->
        error
    end
  end

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
