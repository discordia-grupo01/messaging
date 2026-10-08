defmodule Messaging.Chat.Access.Direct do
  @behaviour Messaging.Chat.Access

  alias Messaging.Chat.{Blocks, ChannelCache}

  @impl true
  def can_view?(%ChannelCache{participants: participants}, user_id, _raw_jwt),
    do: participant(participants, user_id)

  @impl true
  def can_post?(%ChannelCache{} = channel, user_id, _raw_jwt), do: unblocked(channel, user_id)

  @impl true
  def can_delete?(%ChannelCache{} = channel, user_id, _raw_jwt), do: unblocked(channel, user_id)

  defp unblocked(%ChannelCache{participants: participants}, user_id) do
    with {:ok, true} <- participant(participants, user_id) do
      case Blocks.check_contact(user_id, partner(participants, user_id)) do
        :ok -> {:ok, true}
        {:error, reason} when reason in [:user_blocked, :dm_not_delivered] -> {:ok, false}
        {:error, _reason} = error -> error
      end
    end
  end

  @impl true
  def can_moderate?(%ChannelCache{}, _user_id, _raw_jwt), do: {:ok, false}

  defp participant(participants, user_id) do
    if user_id in participants, do: {:ok, true}, else: {:error, :channel_not_found}
  end

  defp partner(participants, user_id), do: Enum.find(participants, &(&1 != user_id))
end
