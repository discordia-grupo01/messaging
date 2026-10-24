defmodule Messaging.Chat.SocketsTest do
  use ExUnit.Case, async: false
  import Mox

  alias Messaging.Chat.Sockets

  setup :verify_on_exit!

  setup do
    previous = Application.get_env(:messaging, :broadcaster)
    on_exit(fn -> Application.put_env(:messaging, :broadcaster, previous) end)
    :ok
  end

  test "revoke_member/3 tells every channel of the server that this user lost access" do
    for id <- ["c-1", "c-2"], do: MessagingWeb.Endpoint.subscribe("channel:" <> id)
    expect(Messaging.Chat.RepoMock, :list_channel_ids, fn "srv-1" -> {:ok, ["c-1", "c-2"]} end)

    assert :ok = Sockets.revoke_member("srv-1", "user-1", "member_left")

    for id <- ["c-1", "c-2"] do
      assert_receive %Phoenix.Socket.Broadcast{
        topic: "channel:" <> ^id,
        event: "access_revoked",
        payload: %{"channel_id" => ^id, "reason" => "member_left", "user_id" => "user-1"}
      }
    end
  end

  test "revoke_member/3 also closes the presence of the server for that user" do
    MessagingWeb.Endpoint.subscribe("presence:srv-1")
    expect(Messaging.Chat.RepoMock, :list_channel_ids, fn "srv-1" -> {:ok, ["c-1"]} end)

    assert :ok = Sockets.revoke_member("srv-1", "user-1", "member_left")

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "presence:srv-1",
      event: "access_revoked",
      payload: %{"server_id" => "srv-1", "reason" => "member_left", "user_id" => "user-1"}
    }
  end

  test "a server without cached channels has nobody to tell" do
    expect(Messaging.Chat.RepoMock, :list_channel_ids, fn _server -> {:ok, []} end)

    assert :ok = Sockets.revoke_member("srv-1", "user-1", "member_left")
    refute_receive %Phoenix.Socket.Broadcast{}, 50
  end

  test "close_channels/2 addresses everybody: the user is nil" do
    MessagingWeb.Endpoint.subscribe("channel:c-9")

    assert :ok = Sockets.close_channels(["c-9"], "channel_deleted")

    assert_receive %Phoenix.Socket.Broadcast{
      event: "access_revoked",
      payload: %{"user_id" => nil, "reason" => "channel_deleted"}
    }
  end

  test "revoke_users/3 tells one channel, once per user, which users lost access" do
    MessagingWeb.Endpoint.subscribe("channel:c-5")

    assert :ok = Sockets.revoke_users("c-5", ["user-1", "user-2"], "permissions_changed")

    for user <- ["user-1", "user-2"] do
      assert_receive %Phoenix.Socket.Broadcast{
        topic: "channel:c-5",
        event: "access_revoked",
        payload: %{"channel_id" => "c-5", "reason" => "permissions_changed", "user_id" => ^user}
      }
    end

    refute_receive %Phoenix.Socket.Broadcast{}, 50
  end

  test "a failure to publish stops the process and is returned, so the event can be retried" do
    Application.put_env(:messaging, :broadcaster, Messaging.FailingBroadcaster)
    expect(Messaging.Chat.RepoMock, :list_channel_ids, fn _server -> {:ok, ["c-1", "c-2"]} end)

    assert {:error, :not_connected} = Sockets.revoke_member("srv-1", "user-1", "member_left")
    assert {:error, :not_connected} = Sockets.close_channels(["c-1"], "channel_deleted")

    assert {:error, :not_connected} =
             Sockets.revoke_users("c-1", ["user-1"], "permissions_changed")
  end

  test "a failure reading the channels is returned" do
    expect(Messaging.Chat.RepoMock, :list_channel_ids, fn _server -> {:error, :timeout} end)

    assert {:error, :timeout} = Sockets.revoke_member("srv-1", "user-1", "member_left")
  end
end
