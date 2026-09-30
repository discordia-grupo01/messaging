defmodule MessagingWeb.RoomChannelTest do
  use MessagingWeb.ChannelCase
  import Mox

  alias Messaging.AuthFixtures
  alias Messaging.Chat
  alias MessagingWeb.RoomChannel

  setup :set_mox_global
  setup :verify_on_exit!

  @channel_id "chan-1"
  @server_id "srv-1"

  defp text_channel_doc,
    do: %{"_id" => @channel_id, "server_id" => @server_id, "name" => "general", "kind" => "text"}

  defp join_socket(user_id) do
    token = AuthFixtures.token_for(user_id)
    {:ok, socket} = connect(MessagingWeb.UserSocket, %{"token" => token})
    socket
  end

  setup do
    stub(Messaging.Chat.RepoMock, :get_channel, fn @channel_id -> text_channel_doc() end)

    stub(Messaging.Chat.PermissionsClientMock, :can_send_messages?, fn _sid, _uid, _jwt ->
      {:ok, true}
    end)

    :ok
  end

  test "a sent message is delivered in real time to every joined member" do
    stub(Messaging.Chat.RepoMock, :insert_message, fn doc -> {:ok, doc} end)

    sender = join_socket("user-a")
    receiver = join_socket("user-b")

    {:ok, _reply, sender_socket} =
      subscribe_and_join(sender, RoomChannel, "channel:" <> @channel_id)

    {:ok, _reply, _receiver_socket} =
      subscribe_and_join(receiver, RoomChannel, "channel:" <> @channel_id)

    ref = push(sender_socket, "new_message", %{"content" => "hola a todos"})
    assert_reply ref, :ok

    assert_push "new_message", %{"content" => "hola a todos", "user_id" => "user-a"}
    assert_push "new_message", %{"content" => "hola a todos", "user_id" => "user-a"}
  end

  test "rejects an empty message" do
    socket = join_socket("user-a")
    {:ok, _reply, socket} = subscribe_and_join(socket, RoomChannel, "channel:" <> @channel_id)

    ref = push(socket, "new_message", %{"content" => "   "})
    assert_reply ref, :error, %{error: %{code: "EMPTY_CONTENT"}}
  end

  test "rejects join without SEND_MESSAGES permission" do
    stub(Messaging.Chat.PermissionsClientMock, :can_send_messages?, fn _sid, _uid, _jwt ->
      {:ok, false}
    end)

    socket = join_socket("user-a")

    assert {:error, %{error: %{code: "FORBIDDEN"}}} =
             subscribe_and_join(socket, RoomChannel, "channel:" <> @channel_id)
  end

  test "rejects sending after permission is revoked mid-session" do
    socket = join_socket("user-a")
    {:ok, _reply, socket} = subscribe_and_join(socket, RoomChannel, "channel:" <> @channel_id)

    stub(Messaging.Chat.PermissionsClientMock, :can_send_messages?, fn _sid, _uid, _jwt ->
      {:ok, false}
    end)

    ref = push(socket, "new_message", %{"content" => "hola"})
    assert_reply ref, :error, %{error: %{code: "FORBIDDEN"}}
  end

  test "rejects a message over the max length" do
    socket = join_socket("user-a")
    {:ok, _reply, socket} = subscribe_and_join(socket, RoomChannel, "channel:" <> @channel_id)

    too_long = String.duplicate("a", Chat.max_message_length() + 1)
    ref = push(socket, "new_message", %{"content" => too_long})
    assert_reply ref, :error, %{error: %{code: "MESSAGE_TOO_LONG"}}
  end

  test "join rejects a channel that doesn't exist locally" do
    stub(Messaging.Chat.RepoMock, :get_channel, fn "missing" -> nil end)
    socket = join_socket("user-a")

    assert {:error, %{error: %{code: "CHANNEL_NOT_FOUND"}}} =
             subscribe_and_join(socket, RoomChannel, "channel:missing")
  end

  test "join with since pushes messages missed while disconnected" do
    missed_doc = %{
      "_id" => "msg-1",
      "channel_id" => @channel_id,
      "server_id" => @server_id,
      "user_id" => "user-b",
      "content" => "te perdiste esto",
      "inserted_at" => ~U[2026-09-28 12:00:01Z]
    }

    stub(Messaging.Chat.RepoMock, :list_messages, fn @channel_id, _opts -> {:ok, [missed_doc]} end)

    socket = join_socket("user-a")

    {:ok, _reply, _socket} =
      subscribe_and_join(socket, RoomChannel, "channel:" <> @channel_id, %{
        "since" => "2026-09-28T12:00:00Z"
      })

    assert_push "missed_messages", %{
      "messages" => [%{"id" => "msg-1", "content" => "te perdiste esto"}]
    }
  end

  test "join rejects a voice channel" do
    stub(Messaging.Chat.RepoMock, :get_channel, fn @channel_id ->
      %{"_id" => @channel_id, "server_id" => @server_id, "name" => "voice-1", "kind" => "voice"}
    end)

    socket = join_socket("user-a")

    assert {:error, %{error: %{code: "CHANNEL_NOT_TEXT"}}} =
             subscribe_and_join(socket, RoomChannel, "channel:" <> @channel_id)
  end
end
