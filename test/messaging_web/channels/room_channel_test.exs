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
    stub(Messaging.Auth.TicketStoreMock, :take, fn _id ->
      {:ok, AuthFixtures.ticket_doc(user_id)}
    end)

    {:ok, socket} = connect(MessagingWeb.UserSocket, %{"ticket" => "a-ticket"})
    socket
  end

  setup do
    stub(Messaging.Chat.RepoMock, :get_channel, fn @channel_id -> text_channel_doc() end)

    stub(Messaging.Chat.PermissionsClientMock, :can_send_messages?, fn _sid, _uid, _jwt ->
      {:ok, true}
    end)

    stub(Messaging.Chat.PermissionsClientMock, :can_view_channel?, fn _sid, _uid, _jwt ->
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

  test "rejects join without VIEW_CHANNELS permission" do
    stub(Messaging.Chat.PermissionsClientMock, :can_view_channel?, fn _sid, _uid, _jwt ->
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

  test "a member who can view but not send joins and receives, but cannot send" do
    stub(Messaging.Chat.PermissionsClientMock, :can_send_messages?, fn _sid, _uid, _jwt ->
      {:ok, false}
    end)

    socket = join_socket("reader")
    {:ok, _reply, socket} = subscribe_and_join(socket, RoomChannel, "channel:" <> @channel_id)

    ref = push(socket, "new_message", %{"content" => "hola"})
    assert_reply ref, :error, %{error: %{code: "FORBIDDEN"}}
  end

  describe "reconnection catch-up" do
    defp doc(id, at),
      do: %{
        "_id" => id,
        "channel_id" => @channel_id,
        "server_id" => @server_id,
        "user_id" => "user-b",
        "content" => "contenido #{id}",
        "inserted_at" => at
      }

    defp join_with(last_message_id) do
      socket = join_socket("user-a")

      subscribe_and_join(socket, RoomChannel, "channel:" <> @channel_id, %{
        "last_message_id" => last_message_id
      })
    end

    test "joining with last_message_id pushes what was sent while disconnected, in order" do
      at = ~U[2026-09-28 12:00:00Z]
      stub(Messaging.Chat.RepoMock, :get_message, fn "msg-0" -> doc("msg-0", at) end)

      stub(Messaging.Chat.RepoMock, :list_messages, fn @channel_id, opts ->
        assert opts[:after] == {at, "msg-0"}
        {:ok, [doc("msg-1", ~U[2026-09-28 12:00:01Z]), doc("msg-2", ~U[2026-09-28 12:00:02Z])]}
      end)

      assert {:ok, _reply, _socket} = join_with("msg-0")

      assert_push "missed_messages", %{
        "messages" => [%{"id" => "msg-1"}, %{"id" => "msg-2"}],
        "next_cursor" => nil
      }
    end

    test "pushes an empty batch when nothing was missed" do
      stub(Messaging.Chat.RepoMock, :get_message, fn "msg-0" ->
        doc("msg-0", ~U[2026-09-28 12:00:00Z])
      end)

      stub(Messaging.Chat.RepoMock, :list_messages, fn @channel_id, _opts -> {:ok, []} end)

      assert {:ok, _reply, _socket} = join_with("msg-0")
      assert_push "missed_messages", %{"messages" => [], "next_cursor" => nil}
    end

    test "returns a cursor when more than one batch was missed" do
      stub(Messaging.Chat.RepoMock, :get_message, fn "msg-0" ->
        doc("msg-0", ~U[2026-09-28 12:00:00Z])
      end)

      stub(Messaging.Chat.RepoMock, :list_messages, fn @channel_id, opts ->
        assert opts[:limit] == Chat.max_page_limit() + 1

        {:ok,
         for(
           i <- 1..(Chat.max_page_limit() + 1),
           do: doc("msg-#{i}", DateTime.add(~U[2026-09-28 12:00:00Z], i))
         )}
      end)

      assert {:ok, _reply, _socket} = join_with("msg-0")

      assert_push "missed_messages", %{"messages" => messages, "next_cursor" => cursor}
      assert length(messages) == Chat.max_page_limit()
      assert cursor == "msg-#{Chat.max_page_limit()}"
    end

    test "joining without last_message_id does not push anything" do
      socket = join_socket("user-a")

      assert {:ok, _reply, _socket} =
               subscribe_and_join(socket, RoomChannel, "channel:" <> @channel_id)

      refute_push "missed_messages", _payload
    end

    test "an unknown last_message_id asks the client to resync instead of failing silently" do
      stub(Messaging.Chat.RepoMock, :get_message, fn "gone" -> nil end)

      assert {:ok, _reply, _socket} = join_with("gone")
      assert_push "resync_required", %{}
      refute_push "missed_messages", _payload
    end

    test "a malformed last_message_id is rejected at join" do
      assert {:error, %{error: %{code: "INVALID_CURSOR"}}} = join_with(%{"$ne" => "x"})
    end

    test "if the catch-up query fails the channel stops so the client rejoins" do
      stub(Messaging.Chat.RepoMock, :get_message, fn "msg-0" ->
        doc("msg-0", ~U[2026-09-28 12:00:00Z])
      end)

      stub(Messaging.Chat.RepoMock, :list_messages, fn @channel_id, _opts ->
        {:error, :timeout}
      end)

      socket = %Phoenix.Socket{assigns: %{channel_id: @channel_id}}

      assert {:stop, :catch_up_failed, ^socket} =
               RoomChannel.handle_info({:after_join, "msg-0"}, socket)
    end
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
