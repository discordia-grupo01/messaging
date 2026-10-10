defmodule Messaging.Chat.PermissionsStore.ReplicaTest do
  use ExUnit.Case, async: true
  import Mox

  alias Messaging.Chat.ChannelCache
  alias Messaging.Chat.PermissionsStore.Replica
  alias Messaging.ReplicaFixtures, as: Fixtures

  setup :verify_on_exit!

  defp member(user_id, role_ids) do
    stub(Messaging.Chat.RepoMock, :get_member, fn "srv-1", ^user_id ->
      Fixtures.member(user_id, role_ids)
    end)
  end

  test "a member with the default role can view and send but not moderate" do
    Fixtures.stub_server("owner-1")
    member("ana", ["everyone"])

    assert {:ok, true} = Replica.can_view_channel?(Fixtures.channel(), "ana")
    assert {:ok, true} = Replica.can_send_messages?(Fixtures.channel(), "ana")
    assert {:ok, false} = Replica.can_manage_messages?(Fixtures.channel(), "ana")
  end

  test "a moderator role adds MANAGE_MESSAGES" do
    Fixtures.stub_server("owner-1")
    member("ana", ["everyone", "mod"])

    assert {:ok, true} = Replica.can_manage_messages?(Fixtures.channel(), "ana")
  end

  test "someone who is not a member can do nothing, without reading anything else" do
    stub(Messaging.Chat.RepoMock, :get_member, fn "srv-1", "stranger" -> nil end)

    assert {:ok, false} = Replica.can_view_channel?(Fixtures.channel(), "stranger")
    assert {:ok, false} = Replica.can_send_messages?(Fixtures.channel(), "stranger")
    assert {:ok, false} = Replica.can_manage_messages?(Fixtures.channel(), "stranger")
  end

  test "the owner can do everything, whatever the channel says" do
    Fixtures.stub_server("ana", [
      Fixtures.override("everyone", [], ["VIEW_CHANNELS", "SEND_MESSAGES"])
    ])

    member("ana", ["everyone"])

    assert {:ok, true} = Replica.can_view_channel?(Fixtures.channel(), "ana")
    assert {:ok, true} = Replica.can_send_messages?(Fixtures.channel(), "ana")
    assert {:ok, true} = Replica.can_manage_messages?(Fixtures.channel(), "ana")
  end

  test "an administrator can do everything, whatever the channel says" do
    Fixtures.stub_server("owner-1", [Fixtures.override("everyone", [], ["VIEW_CHANNELS"])])
    member("ana", ["everyone", "admin"])

    assert {:ok, true} = Replica.can_view_channel?(Fixtures.channel(), "ana")
  end

  test "a channel that denies VIEW_CHANNELS to @everyone is hidden from regular members" do
    Fixtures.stub_server("owner-1", [Fixtures.override("everyone", [], ["VIEW_CHANNELS"])])
    member("ana", ["everyone"])

    assert {:ok, false} = Replica.can_view_channel?(Fixtures.channel(), "ana")
  end

  test "a role override shows the hidden channel again to the people who hold it" do
    overrides = [
      Fixtures.override("everyone", [], ["VIEW_CHANNELS"]),
      Fixtures.override("mod", ["VIEW_CHANNELS"], [])
    ]

    Fixtures.stub_server("owner-1", overrides)

    stub(Messaging.Chat.RepoMock, :get_member, fn "srv-1", user_id ->
      roles = %{"ana" => ["everyone", "mod"], "beto" => ["everyone"]}
      Fixtures.member(user_id, Map.fetch!(roles, user_id))
    end)

    assert {:ok, true} = Replica.can_view_channel?(Fixtures.channel(), "ana")
    assert {:ok, false} = Replica.can_view_channel?(Fixtures.channel(), "beto")
  end

  test "a read-only channel lets everyone read and nobody send" do
    Fixtures.stub_server("owner-1", [Fixtures.override("everyone", [], ["SEND_MESSAGES"])])
    member("ana", ["everyone"])

    assert {:ok, true} = Replica.can_view_channel?(Fixtures.channel(), "ana")
    assert {:ok, false} = Replica.can_send_messages?(Fixtures.channel(), "ana")
  end

  test "a member with the default role can react" do
    Fixtures.stub_server("owner-1")
    member("ana", ["everyone"])

    assert {:ok, true} = Replica.can_add_reactions?(Fixtures.channel(), "ana")
  end

  test "a channel can deny reactions while still allowing to write" do
    Fixtures.stub_server("owner-1", [Fixtures.override("everyone", [], ["ADD_REACTIONS"])])
    member("ana", ["everyone"])

    assert {:ok, true} = Replica.can_send_messages?(Fixtures.channel(), "ana")
    assert {:ok, false} = Replica.can_add_reactions?(Fixtures.channel(), "ana")
  end

  test "the owner and administrators always react" do
    Fixtures.stub_server("owner-1", [Fixtures.override("everyone", [], ["ADD_REACTIONS"])])

    stub(Messaging.Chat.RepoMock, :get_member, fn
      "srv-1", "owner-1" -> Fixtures.member("owner-1", ["everyone"])
      "srv-1", "ana" -> Fixtures.member("ana", ["everyone", "admin"])
    end)

    assert {:ok, true} = Replica.can_add_reactions?(Fixtures.channel(), "owner-1")
    assert {:ok, true} = Replica.can_add_reactions?(Fixtures.channel(), "ana")
  end

  test "a role that was deleted grants nothing" do
    Fixtures.stub_server("owner-1")
    member("ana", ["deleted-role"])

    assert {:ok, false} = Replica.can_view_channel?(Fixtures.channel(), "ana")
  end

  test "a channel without a server is never a server channel" do
    channel = %ChannelCache{channel_id: "dm-1", server_id: nil, name: "", kind: "dm"}

    assert {:ok, false} = Replica.can_view_channel?(channel, "ana")
  end

  test "a failing read is returned, never read as 'allowed' or 'denied'" do
    stub(Messaging.Chat.RepoMock, :get_member, fn _server, _user -> {:error, :timeout} end)

    assert {:error, :timeout} = Replica.can_view_channel?(Fixtures.channel(), "ana")
  end

  test "a failing read of the roles is returned too" do
    member("ana", ["everyone"])
    stub(Messaging.Chat.RepoMock, :get_server_owner, fn _server -> "owner-1" end)
    stub(Messaging.Chat.RepoMock, :list_roles, fn _server -> {:error, :timeout} end)

    assert {:error, :timeout} = Replica.can_send_messages?(Fixtures.channel(), "ana")
  end
end
