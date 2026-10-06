defmodule Messaging.Chat.Access.Direct do
  @behaviour Messaging.Chat.Access

  alias Messaging.Chat.ChannelCache

  @impl true
  def can_view?(%ChannelCache{participants: participants}, user_id, _raw_jwt),
    do: participant(participants, user_id)

  @impl true
  def can_post?(%ChannelCache{participants: participants}, user_id, _raw_jwt),
    do: participant(participants, user_id)

  @impl true
  def can_moderate?(%ChannelCache{}, _user_id, _raw_jwt), do: {:ok, false}

  defp participant(participants, user_id) do
    if user_id in participants, do: {:ok, true}, else: {:error, :channel_not_found}
  end
end
