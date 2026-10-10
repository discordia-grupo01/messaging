defmodule Messaging.Chat.Access.Server do
  @behaviour Messaging.Chat.Access

  alias Messaging.Chat.ChannelCache

  @impl true
  def can_view?(%ChannelCache{} = channel, user_id),
    do: store().can_view_channel?(channel, user_id)

  @impl true
  def can_post?(%ChannelCache{} = channel, user_id),
    do: store().can_send_messages?(channel, user_id)

  @impl true
  def can_delete?(%ChannelCache{} = channel, user_id), do: can_view?(channel, user_id)

  @impl true
  def can_moderate?(%ChannelCache{} = channel, user_id),
    do: store().can_manage_messages?(channel, user_id)

  @impl true
  def can_react?(%ChannelCache{} = channel, user_id),
    do: store().can_add_reactions?(channel, user_id)

  defp store,
    do:
      Application.get_env(:messaging, :permissions_store, Messaging.Chat.PermissionsStore.Replica)
end
