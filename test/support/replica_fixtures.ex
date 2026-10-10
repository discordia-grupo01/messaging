defmodule Messaging.ReplicaFixtures do
  import Mox

  alias Messaging.Chat.ChannelCache

  def server_id, do: "srv-1"
  def channel_id, do: "chan-1"

  def channel,
    do: %ChannelCache{
      channel_id: channel_id(),
      server_id: server_id(),
      name: "general",
      kind: "text"
    }

  def roles,
    do: [
      %{
        "_id" => "everyone",
        "permissions" => ["VIEW_CHANNELS", "SEND_MESSAGES", "ADD_REACTIONS"],
        "is_everyone" => true
      },
      %{"_id" => "mod", "permissions" => ["MANAGE_MESSAGES"], "is_everyone" => false},
      %{"_id" => "vip", "permissions" => ["MENTION_EVERYONE"], "is_everyone" => false},
      %{"_id" => "admin", "permissions" => ["ADMINISTRATOR"], "is_everyone" => false}
    ]

  def member(user_id, role_ids),
    do: %{"_id" => "#{server_id()}:#{user_id}", "user_id" => user_id, "role_ids" => role_ids}

  def stub_server(owner, overrides \\ []) do
    stub(Messaging.Chat.RepoMock, :get_server_owner, fn "srv-1" -> owner end)
    stub(Messaging.Chat.RepoMock, :list_roles, fn "srv-1" -> {:ok, roles()} end)
    stub(Messaging.Chat.RepoMock, :get_channel_overrides, fn "chan-1" -> {:ok, overrides} end)
  end

  def override(role_id, allow, deny),
    do: %{"role_id" => role_id, "allow" => allow, "deny" => deny}
end
