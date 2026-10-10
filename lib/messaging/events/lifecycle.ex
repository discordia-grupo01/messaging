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
         {:ok, _outcome} <-
           Repo.impl().delete_member(event.server_id, event.user_id, event.occurred_at),
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

  # No clock: it only cuts sockets and the join re-checks access, so a duplicate costs one reconnect.
  def handle(%ChannelEvent.ChannelAccessRevoked{} = event) do
    with :ok <- Sockets.revoke_users(event.channel_id, event.user_ids, "permissions_changed") do
      Logger.info("channel_access_revoked_applied",
        channel_id: event.channel_id,
        users: length(event.user_ids)
      )
    end
  end

  def handle(%ChannelEvent.RoleUpdated{} = event) do
    replica_write(event.server_id, "servers.role_updated", fn ->
      Repo.impl().apply_role(
        event.server_id,
        event.role_id,
        event.permissions,
        event.is_everyone,
        event.occurred_at
      )
    end)
  end

  def handle(%ChannelEvent.RoleDeleted{} = event) do
    replica_write(event.server_id, "servers.role_deleted", fn ->
      Repo.impl().delete_role(event.server_id, event.role_id, event.occurred_at)
    end)
  end

  def handle(%ChannelEvent.MemberRolesUpdated{} = event) do
    replica_write(event.server_id, "servers.member_roles_updated", fn ->
      Repo.impl().apply_member_roles(
        event.server_id,
        event.user_id,
        event.role_ids,
        event.occurred_at
      )
    end)
  end

  def handle(%ChannelEvent.ChannelOverridesUpdated{} = event) do
    replica_write(event.server_id, "servers.channel_overrides_updated", fn ->
      Repo.impl().apply_channel_overrides(
        event.server_id,
        event.channel_id,
        event.overrides,
        event.occurred_at
      )
    end)
  end

  def handle(%ChannelEvent.OwnerUpdated{} = event) do
    replica_write(event.server_id, "servers.owner_updated", fn ->
      Repo.impl().apply_server_owner(event.server_id, event.owner_id, event.occurred_at)
    end)
  end

  def handle(%ChannelEvent.ProfileUpdated{} = event) do
    case Repo.impl().apply_profile(event.user_id, event.version) do
      {:ok, :applied} ->
        Logger.info("profile_replicated", user_id: event.user_id, version: event.version)

      {:ok, :stale} ->
        ignored(:stale, "users.profile_updated")

      {:error, _reason} = error ->
        error
    end
  end

  defp replica_write(server_id, routing_key, write) do
    with :alive <- server_state(server_id),
         {:ok, :applied} <- write.() do
      Logger.info("replica_updated", routing_key: routing_key, server_id: server_id)
    else
      :deleted -> ignored(:server_deleted, routing_key)
      {:ok, :stale} -> ignored(:stale, routing_key)
      {:error, _reason} = error -> error
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
