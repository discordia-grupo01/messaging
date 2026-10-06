defmodule Messaging.Chat.Access.Server do
  @behaviour Messaging.Chat.Access

  alias Messaging.Chat.ChannelCache

  @impl true
  def can_view?(%ChannelCache{server_id: server_id}, user_id, raw_jwt),
    do: client().can_view_channel?(server_id, user_id, raw_jwt)

  @impl true
  def can_post?(%ChannelCache{server_id: server_id}, user_id, raw_jwt),
    do: client().can_send_messages?(server_id, user_id, raw_jwt)

  @impl true
  def can_moderate?(%ChannelCache{server_id: server_id}, user_id, raw_jwt),
    do: client().can_manage_messages?(server_id, user_id, raw_jwt)

  defp client,
    do:
      Application.get_env(:messaging, :permissions_client, Messaging.Chat.PermissionsClient.Http)
end
