defmodule Messaging.Chat.Sockets do
  require Logger

  alias Messaging.Chat.Repo
  alias Messaging.Events.Broadcaster
  alias Messaging.Presence.Audience

  @spec revoke_member(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def revoke_member(server_id, user_id, reason) do
    with {:ok, channel_ids} <- Repo.impl().list_channel_ids(server_id),
         :ok <- publish_all(channel_ids, reason, user_id),
         :ok <- revoke_presence(server_id, user_id, reason) do
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

  @spec revoke_users(String.t(), [String.t()], String.t()) :: :ok | {:error, term()}
  def revoke_users(channel_id, user_ids, reason) do
    with :ok <- publish_each(user_ids, &publish(channel_id, reason, &1)) do
      Logger.info("access_revoked",
        channel_id: channel_id,
        users: length(user_ids),
        reason: reason
      )
    end
  end

  defp revoke_presence(server_id, user_id, reason) do
    payload = %{"server_id" => server_id, "reason" => reason, "user_id" => user_id}
    Broadcaster.publish_to(Audience.server_topic(server_id), "access_revoked", payload)
  end

  defp publish_all(channel_ids, reason, user_id),
    do: publish_each(channel_ids, &publish(&1, reason, user_id))

  defp publish_each(items, publish_fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case publish_fun.(item) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp publish(channel_id, reason, user_id) do
    payload = %{"channel_id" => channel_id, "reason" => reason, "user_id" => user_id}
    Broadcaster.publish_to("channel:" <> channel_id, "access_revoked", payload)
  end
end
