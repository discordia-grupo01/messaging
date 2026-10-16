defmodule Messaging.Events.MentionNotifier do
  @moduledoc """
  Sends the highlighted notification of historia #46 in real time: a
  `mention` event on each recipient's personal topic (`user:<id>`), the same
  room `new_dm` uses. The mention is already stored (see `UserMention`) by the
  time this runs, so a failed broadcast only costs the live notice: the user
  still finds it in `GET /v1/mentions`.
  """

  require Logger

  alias Messaging.Chat.Message
  alias Messaging.Events.Broadcaster
  alias Messaging.Log

  @event "mention"

  @spec notify(Message.t(), [String.t()]) :: :ok
  def notify(%Message{}, []), do: :ok

  def notify(%Message{} = message, user_ids) do
    payload = %{
      "server_id" => message.server_id,
      "channel_id" => message.channel_id,
      "message" => Message.to_api(message)
    }

    events = Enum.map(user_ids, &{"user:" <> &1, @event, payload})

    case Broadcaster.publish_many(events) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("mention_broadcast_failed",
          message_id: message.id,
          users: length(user_ids),
          reason: Log.reason(reason)
        )
    end
  end
end
