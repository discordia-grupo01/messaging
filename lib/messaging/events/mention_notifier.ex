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

  @event "mention"

  @spec notify(Message.t(), [String.t()]) :: :ok
  def notify(%Message{}, []), do: :ok

  def notify(%Message{} = message, user_ids) do
    payload = %{
      "server_id" => message.server_id,
      "channel_id" => message.channel_id,
      "message" => Message.to_api(message)
    }

    Enum.each(user_ids, &publish(&1, payload, message.id))
  end

  defp publish(user_id, payload, message_id) do
    case Broadcaster.publish_to("user:" <> user_id, @event, payload) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "messaging: mention_broadcast_failed message_id=#{message_id} user_id=#{user_id} reason=#{inspect(reason)}"
        )
    end
  end
end
