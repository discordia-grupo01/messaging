defmodule Messaging.Chat.PermissionsStore.Replica do
  @behaviour Messaging.Chat.PermissionsStore

  alias Messaging.Chat.{ChannelCache, Permissions, Replica}

  require Logger

  @impl true
  def can_send_messages?(channel, user_id), do: has_permission?(channel, user_id, "SEND_MESSAGES")

  @impl true
  def can_manage_messages?(channel, user_id),
    do: has_permission?(channel, user_id, "MANAGE_MESSAGES")

  @impl true
  def can_view_channel?(channel, user_id), do: has_permission?(channel, user_id, "VIEW_CHANNELS")

  defp has_permission?(%ChannelCache{server_id: nil}, _user_id, _permission), do: {:ok, false}

  defp has_permission?(%ChannelCache{} = channel, user_id, permission) do
    with {:ok, member} <- fetch_member(channel.server_id, user_id) do
      case member do
        nil -> {:ok, false}
        %{"role_ids" => role_ids} -> decide(channel, user_id, role_ids, permission)
      end
    end
  end

  defp decide(channel, user_id, role_ids, permission) do
    with {:ok, snapshot} <- Replica.snapshot(channel.server_id, channel.channel_id) do
      allowed =
        snapshot |> Replica.effective(user_id, role_ids) |> Permissions.can?(permission)

      Logger.debug("permission_checked",
        channel_id: channel.channel_id,
        user_id: user_id,
        permission: permission,
        allowed: allowed
      )

      {:ok, allowed}
    end
  end

  defp fetch_member(server_id, user_id) do
    case repo().get_member(server_id, user_id) do
      {:error, _reason} = error -> error
      member -> {:ok, member}
    end
  end

  defp repo, do: Application.get_env(:messaging, :chat_repo, Messaging.Chat.Repo.Mongo)
end
