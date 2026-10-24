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

  @spec viewable_channel_ids(String.t(), String.t(), [String.t()], [String.t()]) ::
          {:ok, [String.t()]} | {:error, term()}
  def viewable_channel_ids(_server_id, _user_id, _role_ids, []), do: {:ok, []}

  def viewable_channel_ids(server_id, user_id, role_ids, channel_ids) do
    with owner_id when not is_tuple(owner_id) <- repo().get_server_owner(server_id),
         {:ok, roles} <- repo().list_roles(server_id),
         {:ok, overrides_by_channel} <- repo().list_channel_overrides(channel_ids) do
      server = %{owner_id: owner_id, roles: Map.new(roles, &role_entry/1), overrides: %{}}

      {:ok,
       Enum.filter(channel_ids, fn channel_id ->
         overrides = Map.get(overrides_by_channel, channel_id, [])

         %{server | overrides: Map.new(overrides, &override_entry/1)}
         |> effective(user_id, role_ids)
         |> Permissions.can?("VIEW_CHANNELS")
       end)}
    end
  end

  defp role_entry(%{"_id" => id, "permissions" => permissions, "is_everyone" => is_everyone}),
    do: {id, %{permissions: permissions, is_everyone: is_everyone}}

  defp override_entry(%{"role_id" => role_id, "allow" => allow, "deny" => deny}),
    do: {role_id, %{allow: allow, deny: deny}}
end
