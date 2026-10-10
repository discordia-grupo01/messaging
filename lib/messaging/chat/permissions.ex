defmodule Messaging.Chat.Permissions do
  @all ~w(
    VIEW_CHANNELS SEND_MESSAGES MANAGE_CHANNELS MANAGE_ROLES KICK_MEMBERS BAN_MEMBERS
    MANAGE_SERVER ADMINISTRATOR CREATE_INVITE MANAGE_MESSAGES MENTION_EVERYONE ADD_REACTIONS
  )

  @type role :: %{permissions: [String.t()], is_everyone: boolean()}
  @type override :: %{allow: [String.t()], deny: [String.t()]}

  @spec all() :: MapSet.t(String.t())
  def all, do: MapSet.new(@all)

  @spec server_wide(boolean(), [String.t()], %{String.t() => role()}) :: MapSet.t(String.t())
  def server_wide(owner?, role_ids, roles) do
    base = base_permissions(role_ids, roles)
    if unrestricted?(owner?, base), do: all(), else: base
  end

  @spec effective(boolean(), [String.t()], %{String.t() => role()}, %{String.t() => override()}) ::
          MapSet.t(String.t())
  def effective(owner?, role_ids, roles, overrides) do
    base = base_permissions(role_ids, roles)

    if unrestricted?(owner?, base),
      do: all(),
      else: apply_overrides(base, role_ids, roles, overrides)
  end

  @spec can?(MapSet.t(String.t()), String.t()) :: boolean()
  def can?(permissions, permission), do: MapSet.member?(permissions, permission)

  defp base_permissions(role_ids, roles) do
    role_ids
    |> Enum.flat_map(fn id -> permissions_of(roles, id) end)
    |> MapSet.new()
  end

  defp unrestricted?(owner?, base), do: owner? or MapSet.member?(base, "ADMINISTRATOR")

  defp apply_overrides(base, role_ids, roles, overrides) do
    {everyone_ids, other_ids} =
      role_ids
      |> Enum.filter(&Map.has_key?(roles, &1))
      |> Enum.split_with(fn id -> roles[id].is_everyone end)

    after_everyone =
      Enum.reduce(everyone_ids, base, fn id, acc ->
        case Map.get(overrides, id) do
          nil -> acc
          %{allow: allow, deny: deny} -> acc |> remove(deny) |> add(allow)
        end
      end)

    {allow, deny} =
      Enum.reduce(other_ids, {[], []}, fn id, {allow_acc, deny_acc} ->
        case Map.get(overrides, id) do
          nil -> {allow_acc, deny_acc}
          %{allow: allow, deny: deny} -> {allow ++ allow_acc, deny ++ deny_acc}
        end
      end)

    after_everyone |> remove(deny) |> add(allow)
  end

  defp permissions_of(roles, id) do
    case Map.get(roles, id) do
      %{permissions: permissions} -> permissions
      nil -> []
    end
  end

  defp remove(set, names), do: MapSet.difference(set, MapSet.new(names))
  defp add(set, names), do: MapSet.union(set, MapSet.new(names))
end
