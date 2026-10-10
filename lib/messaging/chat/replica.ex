defmodule Messaging.Chat.Replica do
  alias Messaging.Chat.Permissions

  @type snapshot :: %{
          owner_id: String.t() | nil,
          roles: %{String.t() => Permissions.role()},
          overrides: %{String.t() => Permissions.override()}
        }

  defp repo, do: Application.get_env(:messaging, :chat_repo, Messaging.Chat.Repo.Mongo)

  @spec snapshot(String.t(), String.t()) :: {:ok, snapshot()} | {:error, term()}
  def snapshot(server_id, channel_id) do
    with owner_id when not is_tuple(owner_id) <- repo().get_server_owner(server_id),
         {:ok, roles} <- repo().list_roles(server_id),
         {:ok, overrides} <- repo().get_channel_overrides(channel_id) do
      {:ok,
       %{
         owner_id: owner_id,
         roles: Map.new(roles, &role_entry/1),
         overrides: Map.new(overrides, &override_entry/1)
       }}
    end
  end

  @spec effective(snapshot(), String.t(), [String.t()]) :: MapSet.t(String.t())
  def effective(snapshot, user_id, role_ids) do
    Permissions.effective(
      snapshot.owner_id == user_id,
      role_ids,
      snapshot.roles,
      snapshot.overrides
    )
  end

  @spec server_wide(snapshot(), String.t(), [String.t()]) :: MapSet.t(String.t())
  def server_wide(snapshot, user_id, role_ids),
    do: Permissions.server_wide(snapshot.owner_id == user_id, role_ids, snapshot.roles)

  defp role_entry(%{"_id" => id, "permissions" => permissions, "is_everyone" => is_everyone}),
    do: {id, %{permissions: permissions, is_everyone: is_everyone}}

  defp override_entry(%{"role_id" => role_id, "allow" => allow, "deny" => deny}),
    do: {role_id, %{allow: allow, deny: deny}}
end
