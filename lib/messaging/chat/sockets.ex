defmodule Messaging.Chat.Sockets do
  require Logger

  alias Messaging.Chat.Repo
  alias Messaging.Events.Broadcaster

  @spec revoke_member(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def revoke_member(server_id, user_id, reason) do
    with {:ok, channel_ids} <- Repo.impl().list_channel_ids(server_id),
         :ok <- publish_all(channel_ids, reason, user_id) do
      Logger.info("access_revoked",
        server_id: server_id,
        user_id: user_id,
        channels: length(channel_ids),
        reason: reason
      )
    end
  end

  @spec close_channels([String.t()], String.t()) :: :ok | {:error, term()}
  def close_channels(channel_ids, reason) do
    with :ok <- publish_all(channel_ids, reason, nil) do
      Logger.info("channels_closed", channels: length(channel_ids), reason: reason)
    end
  end

  defp publish_all(channel_ids, reason, user_id) do
    Enum.reduce_while(channel_ids, :ok, fn channel_id, :ok ->
      payload = %{"channel_id" => channel_id, "reason" => reason, "user_id" => user_id}

      case Broadcaster.publish_to("channel:" <> channel_id, "access_revoked", payload) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end
end
