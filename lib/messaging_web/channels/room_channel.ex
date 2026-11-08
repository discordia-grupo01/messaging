defmodule MessagingWeb.RoomChannel do
  use Phoenix.Channel
  require Logger

  alias Messaging.Chat
  alias Messaging.Chat.Message
  alias Messaging.Events.Broadcaster
  alias Messaging.Log
  alias Messaging.Suspension
  alias Messaging.Tracing
  alias MessagingWeb.ApiError
  alias MessagingWeb.MessagePayload

  @dialyzer {:nowarn_function, handle_info: 2}

  @traced_events [
    "new_message",
    "edit_message",
    "delete_message",
    "add_reaction",
    "remove_reaction"
  ]

  intercept ["access_revoked"]

  @impl true
  def join("channel:" <> channel_id, params, socket) do
    user_id = socket.assigns.user_id
    last_message_id = Map.get(params, "last_message_id")

    with :ok <- Suspension.ensure_active(user_id),
         :ok <- validate_cursor(last_message_id),
         {:ok, changes_since} <- parse_changes_since(Map.get(params, "changes_since")),
         {:ok, channel} <- Chat.channel_exists?(channel_id),
         {:ok, true} <- Chat.can_view_channel?(channel, user_id) do
      socket = assign(socket, channel_id: channel_id)
      send(self(), {:after_join, last_message_id, changes_since})
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
        Logger.error("catch_up_failed",
          channel_id: socket.assigns.channel_id,
          reason: Log.reason(reason)
        )

        {:stop, :catch_up_failed, socket}
    end
  end

  @impl true
  def handle_out("access_revoked", %{"user_id" => target} = payload, socket) do
    if is_nil(target) or target == socket.assigns.user_id do
      push(socket, "access_revoked", Map.take(payload, ["channel_id", "reason"]))
      {:stop, :shutdown, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_in(event, payload, socket) do
    Tracing.ws_span(traced_event(event), fn ->
      case Suspension.ensure_active(socket.assigns.user_id) do
        :ok -> dispatch(event, payload, socket)
        {:error, reason} -> error_reply(reason, socket)
      end
    end)
  end

  defp traced_event(event) when event in @traced_events, do: event
  defp traced_event(_event), do: "other"

  defp error_reply(reason, socket) do
    if ApiError.http_status(reason) >= 500, do: Tracing.mark_error()
    {:reply, {:error, ApiError.payload(reason)}, socket}
  end

  defp dispatch("new_message", payload, socket) when is_map(payload) do
    with {:ok, content} <- MessagePayload.content(payload),
         {:ok, client_id} <- MessagePayload.client_id(payload) do
      params = %{
        channel_id: socket.assigns.channel_id,
        user_id: socket.assigns.user_id,
        content: content,
        attachment_ids: Map.get(payload, "attachment_ids"),
        client_id: client_id
      }

      case Chat.send_message(params) do
        {:ok, message} ->
          {:reply, {:ok, Message.to_api(message)}, socket}

        {:error, reason} ->
          error_reply(reason, socket)
      end
    else
      :error -> error_reply(:invalid_payload, socket)
    end
  end

  defp dispatch("edit_message", %{"id" => message_id, "content" => content}, socket) do
    params = %{
      channel_id: socket.assigns.channel_id,
      message_id: message_id,
      user_id: socket.assigns.user_id,
      content: content
    }

    case Chat.edit_message(params) do
      {:ok, message, _change} ->
        {:reply, {:ok, Message.to_api(message)}, socket}

      {:error, reason} ->
        error_reply(reason, socket)
    end
  end

  defp dispatch("delete_message", %{"id" => message_id}, socket) do
    params = %{
      channel_id: socket.assigns.channel_id,
      message_id: message_id,
      user_id: socket.assigns.user_id
    }

    case Chat.delete_message(params) do
      {:ok, _message} ->
        {:reply, :ok, socket}

      {:error, reason} ->
        error_reply(reason, socket)
    end
  end

  defp dispatch(event, %{"message_id" => message_id, "emoji" => emoji}, socket)
       when event in ["add_reaction", "remove_reaction"] do
    params = %{
      channel_id: socket.assigns.channel_id,
      message_id: message_id,
      user_id: socket.assigns.user_id,
      emoji: emoji
    }

    {action, result} =
      if event == "add_reaction",
        do: {"added", Chat.add_reaction(params)},
        else: {"removed", Chat.remove_reaction(params)}

    case result do
      {:ok, reaction} ->
        if reaction.changed, do: publish_reaction(reaction, socket.assigns.user_id, action)

        {:reply,
         {:ok,
          %{
            "emoji" => reaction.emoji,
            "count" => reaction.count,
            "reacted_by_me" => action == "added"
          }}, socket}

      {:error, reason} ->
        error_reply(reason, socket)
    end
  end

  defp dispatch(event, _payload, socket)
       when event in [
              "new_message",
              "edit_message",
              "delete_message",
              "add_reaction",
              "remove_reaction"
            ] do
    error_reply(:invalid_payload, socket)
  end

  defp publish_reaction(reaction, user_id, action) do
    case Broadcaster.publish("reaction_updated", Message.reaction_api(reaction, user_id, action)) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("reaction_updated_broadcast_failed",
          message_id: reaction.message.id,
          reason: Log.reason(reason)
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
    with {:ok, messages, deleted_ids} <- Chat.list_changes(socket.assigns.channel_id, since),
         {:ok, reactions} <- Chat.reactions_for(messages, socket.assigns.user_id) do
      push(socket, "changed_messages", %{
        "messages" => Enum.map(messages, &Message.to_api(&1, reactions)),
        "deleted_ids" => deleted_ids
      })

      :ok
    else
      {:error, :too_many_changes} ->
        push(socket, "resync_required", %{})
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp push_missed_messages(_socket, nil), do: :ok

  defp push_missed_messages(socket, last_message_id) do
    with {:ok, messages, next_cursor} <-
           Chat.list_messages(socket.assigns.channel_id,
             after: last_message_id,
             limit: Chat.max_page_limit()
           ),
         {:ok, reactions} <- Chat.reactions_for(messages, socket.assigns.user_id) do
      push(socket, "missed_messages", %{
        "messages" => Enum.map(messages, &Message.to_api(&1, reactions)),
        "next_cursor" => next_cursor
      })

      :ok
    else
      {:error, :invalid_cursor} ->
        push(socket, "resync_required", %{})
        :ok

      {:error, _reason} = error ->
        error
    end
  end
end
