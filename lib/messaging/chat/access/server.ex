defmodule Messaging.Chat.Access.Server do
  @behaviour Messaging.Chat.Access

  alias Messaging.Chat.ChannelCache

  @impl true
  def can_view?(%ChannelCache{channel_id: channel_id}, user_id, raw_jwt),
    do: client().can_view_channel?(channel_id, user_id, raw_jwt)

  @impl true
  def can_post?(%ChannelCache{channel_id: channel_id}, user_id, raw_jwt),
    do: client().can_send_messages?(channel_id, user_id, raw_jwt)

  @impl true
  def can_delete?(%ChannelCache{} = channel, user_id, raw_jwt),
    do: can_view?(channel, user_id, raw_jwt)

  @impl true
  def can_moderate?(%ChannelCache{channel_id: channel_id}, user_id, raw_jwt),
    do: client().can_manage_messages?(channel_id, user_id, raw_jwt)

  defp client,
    do:
      Application.get_env(:messaging, :permissions_client, Messaging.Chat.PermissionsClient.Http)
end
