defmodule Messaging.Chat.MentionResolver.Replica do
  @behaviour Messaging.Chat.MentionResolver

  alias Messaging.Chat.{ChannelCache, Mentions, Permissions, Replica}

  @impl true
  def resolve(%ChannelCache{server_id: server_id} = channel, query, actor_id) do
    with {:ok, snapshot} <- Replica.snapshot(server_id, channel.channel_id),
         {:ok, actor} <- fetch_actor(server_id, actor_id) do
      mentions_everyone? =
        snapshot
        |> Replica.server_wide(actor_id, actor["role_ids"])
        |> Permissions.can?("MENTION_EVERYONE")

      resolve_for(channel, snapshot, query, actor_id, mentions_everyone?)
    end
  end

  defp resolve_for(channel, snapshot, query, actor_id, mentions_everyone?) do
    server_id = channel.server_id
    role_ids = if mentions_everyone?, do: mentionable_roles(snapshot, query.role_ids), else: []
    everyone? = mentions_everyone? and query.everyone

    with {:ok, mentioned} <- repo().get_members(server_id, query.user_ids),
         {:ok, candidates} <- candidates(server_id, mentioned, role_ids, everyone?) do
      user_ids = mentioned |> Enum.map(& &1["user_id"]) |> Enum.sort()

      recipients =
        candidates
        |> Enum.filter(&can_view?(snapshot, &1))
        |> Enum.map(& &1["user_id"])
        |> Enum.reject(&(&1 == actor_id))
        |> Enum.uniq()
        |> Enum.sort()

      {:ok,
       %Mentions{
         user_ids: user_ids,
         role_ids: role_ids,
         everyone: everyone?,
         recipient_ids: recipients
       }}
    end
  end

  defp fetch_actor(server_id, actor_id) do
    case repo().get_member(server_id, actor_id) do
      %{"role_ids" => _role_ids} = member -> {:ok, member}
      nil -> {:error, :not_a_member}
      {:error, _reason} = error -> error
    end
  end

  defp mentionable_roles(snapshot, requested) do
    requested
    |> Enum.filter(fn id ->
      match?(%{is_everyone: false}, Map.get(snapshot.roles, id))
    end)
    |> Enum.sort()
  end

  defp candidates(server_id, _mentioned, _role_ids, true), do: repo().list_members(server_id)

  defp candidates(_server_id, mentioned, [], false), do: {:ok, mentioned}

  defp candidates(server_id, mentioned, role_ids, false) do
    with {:ok, members} <- repo().list_members(server_id) do
      holders = Enum.filter(members, fn m -> Enum.any?(m["role_ids"], &(&1 in role_ids)) end)
      {:ok, Enum.uniq_by(mentioned ++ holders, & &1["user_id"])}
    end
  end

  defp can_view?(snapshot, %{"user_id" => user_id, "role_ids" => role_ids}) do
    snapshot |> Replica.effective(user_id, role_ids) |> Permissions.can?("VIEW_CHANNELS")
  end

  defp repo, do: Application.get_env(:messaging, :chat_repo, Messaging.Chat.Repo.Mongo)
end
