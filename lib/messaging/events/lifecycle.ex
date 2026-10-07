defmodule Messaging.Events.Lifecycle do
  require Logger

  alias Messaging.Chat
  alias Messaging.Chat.{ChannelCache, Repo, Sockets}
  alias Messaging.Events.ChannelEvent

  @tombstone_ttl_seconds 7 * 24 * 60 * 60

  @type result :: :ok | {:ignored, :stale | :server_deleted} | {:error, term()}

  @spec handle(struct()) :: result()
  def handle(%ChannelEvent.ChannelCreated{} = event) do
    with :alive <- server_state(event.server_id),
         {:ok, :applied} <- clock(channel_key(event.channel_id), "created", event.occurred_at),
         :ok <-
           Chat.upsert_channel(%ChannelCache{
             channel_id: event.channel_id,
             server_id: event.server_id,
             name: event.name,
             kind: event.kind
           }) do
      Logger.info("channel_created_applied", channel_id: event.channel_id)
    else
      :deleted -> ignored(:server_deleted, "servers.channel_created")
      {:ok, :stale} -> ignored(:stale, "servers.channel_created")
      {:error, _reason} = error -> error
    end
  end

  def handle(%ChannelEvent.ChannelDeleted{} = event) do
    with {:ok, :applied} <-
           clock(channel_key(event.channel_id), "deleted", event.occurred_at, tombstone_expiry()),
         :ok <- Chat.delete_channel(event.channel_id),
         :ok <- Sockets.close_channels([event.channel_id], "channel_deleted") do
      Logger.info("channel_deleted_applied", channel_id: event.channel_id)
    else
      {:ok, :stale} -> ignored(:stale, "servers.channel_deleted")
      {:error, _reason} = error -> error
    end
  end

  def handle(%ChannelEvent.ServerDeleted{} = event) do
    with {:ok, :applied} <-
           clock(server_key(event.server_id), "deleted", event.occurred_at, tombstone_expiry()),
         {:ok, cached_ids} <- Repo.impl().list_channel_ids(event.server_id),
         channel_ids = Enum.uniq(event.channel_ids ++ cached_ids),
         :ok <- Chat.delete_server_data(event.server_id, event.channel_ids),
         :ok <- Sockets.close_channels(channel_ids, "server_deleted") do
      Logger.info("server_deleted_applied",
        server_id: event.server_id,
        channels: length(channel_ids)
      )
    else
      {:ok, :stale} -> ignored(:stale, "servers.server_deleted")
      {:error, _reason} = error -> error
    end
  end

  def handle(%ChannelEvent.MemberJoined{} = event) do
    case clock(member_key(event), "joined", event.occurred_at) do
      {:ok, :applied} ->
        Logger.info("member_joined_applied", server_id: event.server_id, user_id: event.user_id)

      {:ok, :stale} ->
        ignored(:stale, "servers.member_joined")

      {:error, _reason} = error ->
        error
    end
  end

  def handle(%ChannelEvent.MemberLeft{} = event) do
    with {:ok, :applied} <- clock(member_key(event), "left", event.occurred_at),
         :ok <- Chat.delete_member_mentions(event.server_id, event.user_id),
         :ok <- Sockets.revoke_member(event.server_id, event.user_id, "member_left") do
      Logger.info("member_left_applied", server_id: event.server_id, user_id: event.user_id)
    else
      {:ok, :stale} -> ignored(:stale, "servers.member_left")
      {:error, _reason} = error -> error
    end
  end

  def handle(%ChannelEvent.MemberMuted{} = event) do
    case clock(member_mute_key(event), "muted", event.occurred_at, event.until_at) do
      {:ok, :applied} ->
        Logger.info("member_muted_applied", server_id: event.server_id, user_id: event.user_id)

      {:ok, :stale} ->
        ignored(:stale, "servers.member_muted")

      {:error, _reason} = error ->
        error
    end
  end

  def handle(%ChannelEvent.MemberUnmuted{} = event) do
    case clock(member_mute_key(event), "unmuted", event.occurred_at) do
      {:ok, :applied} ->
        Logger.info("member_unmuted_applied", server_id: event.server_id, user_id: event.user_id)

      {:ok, :stale} ->
        ignored(:stale, "servers.member_unmuted")

      {:error, _reason} = error ->
        error
    end
  end

  defp server_state(server_id) do
    case Repo.impl().get_clock(server_key(server_id)) do
      %{"state" => "deleted"} -> :deleted
      {:error, _reason} = error -> error
      _alive -> :alive
    end
  end

  defp clock(key, state, at, expires_at \\ nil),
    do: Repo.impl().apply_clock(key, state, at, expires_at)

  defp ignored(cause, routing_key) do
    Logger.info("event_ignored", cause: to_string(cause), routing_key: routing_key)
    {:ignored, cause}
  end

  defp tombstone_expiry, do: DateTime.add(DateTime.utc_now(), @tombstone_ttl_seconds, :second)

  defp channel_key(channel_id), do: "channel:" <> channel_id
  defp server_key(server_id), do: "server:" <> server_id
  defp member_key(%{server_id: server_id, user_id: user_id}), do: "member:#{server_id}:#{user_id}"

  defp member_mute_key(%{server_id: server_id, user_id: user_id}),
    do: "member_mute:#{server_id}:#{user_id}"
end
