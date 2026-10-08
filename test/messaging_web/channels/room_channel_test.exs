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

  describe "edit_message" do
    defp stored_message(overrides \\ %{}) do
      Map.merge(
        %{
          "_id" => "msg-1",
          "channel_id" => @channel_id,
          "server_id" => @server_id,
          "user_id" => "user-a",
          "content" => "texto original",
          "inserted_at" => ~U[2026-09-28 12:00:00Z]
        },
        overrides
      )
    end

    defp stub_stored(doc \\ stored_message()) do
      stub(Messaging.Chat.RepoMock, :get_message, fn "msg-1" -> doc end)

      stub(Messaging.Chat.RepoMock, :update_message, fn "msg-1",
                                                        _cid,
                                                        _uid,
                                                        content,
                                                        edited_at,
                                                        _mention_fields ->
        {:ok, Map.merge(doc, %{"content" => content, "edited_at" => edited_at})}
      end)
    end

    defp join_as(user_id) do
      {:ok, _reply, socket} =
        subscribe_and_join(join_socket(user_id), RoomChannel, "channel:" <> @channel_id)

      socket
    end

    test "CA1+CA3: the author's edit reaches every member with the channel open, marked as edited" do
      stub_stored()
      author = join_as("user-a")
      _reader = join_as("user-b")

      ref = push(author, "edit_message", %{"id" => "msg-1", "content" => "texto corregido"})

      assert_reply ref, :ok, %{
        "id" => "msg-1",
        "content" => "texto corregido",
        "edited" => true,
        "edited_at" => edited_at
      }

      assert is_binary(edited_at)

      for _member <- 1..2 do
        assert_push "message_updated", %{
          "id" => "msg-1",
          "content" => "texto corregido",
          "edited" => true,
          "inserted_at" => "2026-09-28T12:00:00Z"
        }
      end
    end

    test "CA2: someone who is not the author is rejected and nobody sees a change" do
      stub_stored()
      intruder = join_as("user-b")

      ref = push(intruder, "edit_message", %{"id" => "msg-1", "content" => "ahora es mio"})

      assert_reply ref, :error, %{error: %{code: "NOT_MESSAGE_AUTHOR"}}
      refute_push "message_updated", _payload
    end

    test "an edit that changes nothing replies ok, stays unmarked and emits nothing" do
      stub_stored()
      author = join_as("user-a")

      ref = push(author, "edit_message", %{"id" => "msg-1", "content" => " texto original "})

      assert_reply ref, :ok, %{"edited" => false, "edited_at" => nil}
      refute_push "message_updated", _payload
    end

    test "rejects empty and over-long content" do
      stub_stored()
      author = join_as("user-a")

      ref = push(author, "edit_message", %{"id" => "msg-1", "content" => "   "})
      assert_reply ref, :error, %{error: %{code: "EMPTY_CONTENT"}}

      too_long = String.duplicate("a", Chat.max_message_length() + 1)
      ref = push(author, "edit_message", %{"id" => "msg-1", "content" => too_long})
      assert_reply ref, :error, %{error: %{code: "MESSAGE_TOO_LONG"}}
      refute_push "message_updated", _payload
    end

    test "a message that does not exist" do
      stub(Messaging.Chat.RepoMock, :get_message, fn "ghost" -> nil end)
      author = join_as("user-a")

      ref = push(author, "edit_message", %{"id" => "ghost", "content" => "hola"})

      assert_reply ref, :error, %{error: %{code: "MESSAGE_NOT_FOUND"}}
    end

    test "losing SEND_MESSAGES after joining blocks the edit" do
      stub_stored()
      author = join_as("user-a")

      stub(Messaging.Chat.PermissionsClientMock, :can_send_messages?, fn _sid, _uid, _jwt ->
        {:ok, false}
      end)

      ref = push(author, "edit_message", %{"id" => "msg-1", "content" => "hola"})

      assert_reply ref, :error, %{error: %{code: "FORBIDDEN"}}
      refute_push "message_updated", _payload
    end

    test "malformed payloads get an error reply instead of crashing the channel" do
      stub_stored()
      author = join_as("user-a")

      for payload <- [%{}, %{"id" => "msg-1"}, %{"content" => "hola"}] do
        ref = push(author, "edit_message", payload)
        assert_reply ref, :error, %{error: %{code: "INVALID_PAYLOAD"}}
      end

      ref = push(author, "new_message", %{"texto" => "sin content"})
      assert_reply ref, :error, %{error: %{code: "INVALID_PAYLOAD"}}

      stub(Messaging.Chat.RepoMock, :insert_message, fn doc -> {:ok, doc} end)
      ref = push(author, "new_message", %{"content" => "sigue funcionando"})
      assert_reply ref, :ok
    end

    test "a message id that is not a string cannot be used to query the database" do
      author = join_as("user-a")

      ref = push(author, "edit_message", %{"id" => %{"$ne" => "x"}, "content" => "hola"})

      assert_reply ref, :error, %{error: %{code: "MESSAGE_NOT_FOUND"}}
    end

    test "if the realtime broadcast fails the edit is still saved and acknowledged" do
      stub_stored()
      previous = Application.get_env(:messaging, :broadcaster)
      Application.put_env(:messaging, :broadcaster, Messaging.FailingBroadcaster)
      on_exit(fn -> Application.put_env(:messaging, :broadcaster, previous) end)
      author = join_as("user-a")

      ref = push(author, "edit_message", %{"id" => "msg-1", "content" => "texto corregido"})

      assert_reply ref, :ok, %{"edited" => true}
    end
  end

  describe "delete_message" do
    defp stub_deletable(doc \\ stored_message()) do
      stub(Messaging.Chat.RepoMock, :get_message, fn "msg-1" -> doc end)

      stub(Messaging.Chat.RepoMock, :delete_message, fn "msg-1", _cid, deleted_at ->
        {:ok, Map.merge(doc, %{"content" => "", "deleted_at" => deleted_at})}
      end)
    end

    test "CA1: the author's deletion reaches every member with the channel open" do
      stub_deletable()
      author = join_as("user-a")
      _reader = join_as("user-b")

      ref = push(author, "delete_message", %{"id" => "msg-1"})

      assert_reply ref, :ok

      for _member <- 1..2 do
        assert_push "message_deleted", %{
          "id" => "msg-1",
          "channel_id" => @channel_id,
          "server_id" => @server_id,
          "deleted_at" => deleted_at
        }

        assert is_binary(deleted_at)
      end
    end

    test "the deletion event never carries the content of the message" do
      stub_deletable()
      author = join_as("user-a")

      ref = push(author, "delete_message", %{"id" => "msg-1"})
      assert_reply ref, :ok

      assert_push "message_deleted", payload
      refute Map.has_key?(payload, "content")
      refute Map.has_key?(payload, "user_id")
    end

    test "CA2: a member with MANAGE_MESSAGES deletes someone else's message" do
      stub_deletable()

      stub(Messaging.Chat.PermissionsClientMock, :can_manage_messages?, fn _sid, _uid, _jwt ->
        {:ok, true}
      end)

      moderator = join_as("moderator")

      ref = push(moderator, "delete_message", %{"id" => "msg-1"})

      assert_reply ref, :ok
      assert_push "message_deleted", %{"id" => "msg-1"}
    end

    test "CA3: someone without authorship or moderation is rejected and nobody sees a change" do
      stub_deletable()

      stub(Messaging.Chat.PermissionsClientMock, :can_manage_messages?, fn _sid, _uid, _jwt ->
        {:ok, false}
      end)

      intruder = join_as("user-b")

      ref = push(intruder, "delete_message", %{"id" => "msg-1"})

      assert_reply ref, :error, %{error: %{code: "MESSAGE_DELETE_DENIED"}}
      refute_push "message_deleted", _payload
    end

    test "a message that does not exist or was already deleted" do
      stub(Messaging.Chat.RepoMock, :get_message, fn "ghost" -> nil end)
      author = join_as("user-a")

      ref = push(author, "delete_message", %{"id" => "ghost"})

      assert_reply ref, :error, %{error: %{code: "MESSAGE_NOT_FOUND"}}

      stub(Messaging.Chat.RepoMock, :get_message, fn "gone" ->
        stored_message(%{
          "_id" => "gone",
          "content" => "",
          "deleted_at" => ~U[2026-09-28 12:05:00Z]
        })
      end)

      ref = push(author, "delete_message", %{"id" => "gone"})
      assert_reply ref, :error, %{error: %{code: "MESSAGE_NOT_FOUND"}}
      refute_push "message_deleted", _payload
    end

    test "losing VIEW_CHANNELS after joining blocks the deletion, even for the author" do
      stub_deletable()
      author = join_as("user-a")

      stub(Messaging.Chat.PermissionsClientMock, :can_view_channel?, fn _sid, _uid, _jwt ->
        {:ok, false}
      end)

      ref = push(author, "delete_message", %{"id" => "msg-1"})

      assert_reply ref, :error, %{error: %{code: "FORBIDDEN"}}
      refute_push "message_deleted", _payload
    end

    test "malformed payloads get an error reply instead of crashing the channel" do
      author = join_as("user-a")

      for payload <- [%{}, %{"mensaje" => "msg-1"}] do
        ref = push(author, "delete_message", payload)
        assert_reply ref, :error, %{error: %{code: "INVALID_PAYLOAD"}}
      end
    end

    test "a message id that is not a string cannot be used to query the database" do
      author = join_as("user-a")

      ref = push(author, "delete_message", %{"id" => %{"$ne" => "x"}})

      assert_reply ref, :error, %{error: %{code: "MESSAGE_NOT_FOUND"}}
    end

    test "if the realtime broadcast fails the deletion is still saved and acknowledged" do
      stub_deletable()
      previous = Application.get_env(:messaging, :broadcaster)
      Application.put_env(:messaging, :broadcaster, Messaging.FailingBroadcaster)
      on_exit(fn -> Application.put_env(:messaging, :broadcaster, previous) end)
      author = join_as("user-a")

      ref = push(author, "delete_message", %{"id" => "msg-1"})

      assert_reply ref, :ok
    end
  end

  describe "access revoked" do
    setup do
      Process.flag(:trap_exit, true)
      :ok
    end

    defp revoke(user_id, reason \\ "member_left") do
      MessagingWeb.Endpoint.broadcast("channel:" <> @channel_id, "access_revoked", %{
        "channel_id" => @channel_id,
        "reason" => reason,
        "user_id" => user_id
      })
    end

    test "the user who lost access is told why and the channel closes by itself" do
      member = join_as("user-a")
      ref = Process.monitor(member.channel_pid)

      revoke("user-a")

      assert_push "access_revoked", %{"channel_id" => @channel_id, "reason" => "member_left"}
      assert_receive {:DOWN, ^ref, :process, _pid, :shutdown}
    end

    test "the notification does not carry the user id, only the channel and the reason" do
      _member = join_as("user-a")

      revoke("user-a")

      assert_push "access_revoked", payload
      assert Map.keys(payload) |> Enum.sort() == ["channel_id", "reason"]
    end

    test "everybody else in the channel keeps their connection and keeps receiving" do
      stub(Messaging.Chat.RepoMock, :insert_message, fn doc -> {:ok, doc} end)
      kicked = join_as("user-a")
      stays = join_as("user-b")
      kicked_ref = Process.monitor(kicked.channel_pid)
      stays_ref = Process.monitor(stays.channel_pid)

      revoke("user-a")

      assert_receive {:DOWN, ^kicked_ref, :process, _pid, :shutdown}
      refute_receive {:DOWN, ^stays_ref, :process, _pid, _reason}, 100

      ref = push(stays, "new_message", %{"content" => "sigo aca"})
      assert_reply ref, :ok
    end

    test "a deletion has no user: it closes every member's channel" do
      first = join_as("user-a")
      second = join_as("user-b")
      refs = for socket <- [first, second], do: Process.monitor(socket.channel_pid)

      revoke(nil, "channel_deleted")

      for ref <- refs, do: assert_receive({:DOWN, ^ref, :process, _pid, :shutdown})
      assert_push "access_revoked", %{"reason" => "channel_deleted"}
    end

    test "a revoked user who tries to come back is refused at the join" do
      stub(Messaging.Chat.PermissionsClientMock, :can_view_channel?, fn _c, _u, _jwt ->
        {:ok, false}
      end)

      assert {:error, %{error: %{code: "FORBIDDEN"}}} =
               subscribe_and_join(join_socket("user-a"), RoomChannel, "channel:" <> @channel_id)
    end
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
               RoomChannel.handle_info({:after_join, "msg-0", nil}, socket)
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

  describe "change feed on reconnect" do
    defp edited_doc(id, edited_at) do
      %{
        "_id" => id,
        "channel_id" => @channel_id,
        "server_id" => @server_id,
        "user_id" => "user-b",
        "content" => "texto de #{id}",
        "inserted_at" => ~U[2026-09-28 10:00:00Z],
        "edited_at" => edited_at,
        "changed_at" => edited_at
      }
    end

    defp join_since(since) do
      subscribe_and_join(join_socket("user-a"), RoomChannel, "channel:" <> @channel_id, %{
        "changes_since" => since
      })
    end

    test "every join replies with the server's clock so the client can use it as its cursor" do
      {:ok, reply, _socket} =
        subscribe_and_join(join_socket("user-a"), RoomChannel, "channel:" <> @channel_id)

      assert %{"server_time" => server_time} = reply
      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(server_time)
      assert String.ends_with?(server_time, "Z")
    end

    test "joining with changes_since pushes what was edited meanwhile, even very old messages" do
      since = ~U[2026-09-28 12:00:00Z]

      stub(Messaging.Chat.RepoMock, :list_changes, fn @channel_id, from, 201 ->
        assert DateTime.compare(from, DateTime.add(since, -5, :second)) == :eq

        {:ok,
         [
           edited_doc("old-msg", ~U[2026-09-28 12:01:00Z]),
           edited_doc("other-msg", ~U[2026-09-28 12:02:00Z])
         ]}
      end)

      assert {:ok, _reply, _socket} = join_since("2026-09-28T12:00:00Z")

      assert_push "changed_messages", %{
        "messages" => [
          %{"id" => "old-msg", "edited" => true, "inserted_at" => "2026-09-28T10:00:00Z"},
          %{"id" => "other-msg", "edited" => true}
        ]
      }
    end

    test "messages deleted while disconnected arrive as ids, apart from the edited ones" do
      tombstone =
        edited_doc("gone", ~U[2026-09-28 12:03:00Z])
        |> Map.merge(%{"content" => "", "deleted_at" => ~U[2026-09-28 12:03:00Z]})

      stub(Messaging.Chat.RepoMock, :list_changes, fn _cid, _from, _limit ->
        {:ok, [edited_doc("kept", ~U[2026-09-28 12:01:00Z]), tombstone]}
      end)

      assert {:ok, _reply, _socket} = join_since("2026-09-28T12:00:00Z")

      assert_push "changed_messages", %{
        "messages" => [%{"id" => "kept", "edited" => true}],
        "deleted_ids" => ["gone"]
      }
    end

    test "an empty batch is still pushed so the client knows it is up to date" do
      stub(Messaging.Chat.RepoMock, :list_changes, fn _cid, _from, _limit -> {:ok, []} end)

      assert {:ok, _reply, _socket} = join_since("2026-09-28T12:00:00Z")
      assert_push "changed_messages", %{"messages" => [], "deleted_ids" => []}
    end

    test "joining without changes_since does not look for changes" do
      assert {:ok, _reply, _socket} =
               subscribe_and_join(join_socket("user-a"), RoomChannel, "channel:" <> @channel_id)

      refute_push "changed_messages", _payload
    end

    test "too many changes asks the client to resync instead of sending a partial list" do
      docs = for i <- 1..201, do: edited_doc("m-#{i}", ~U[2026-09-28 12:01:00Z])
      stub(Messaging.Chat.RepoMock, :list_changes, fn _cid, _from, _limit -> {:ok, docs} end)

      assert {:ok, _reply, _socket} = join_since("2026-09-28T12:00:00Z")

      assert_push "resync_required", %{}
      refute_push "changed_messages", _payload
    end

    test "missed new messages and changes are both delivered, new messages first" do
      stub(Messaging.Chat.RepoMock, :get_message, fn "msg-0" ->
        edited_doc("msg-0", ~U[2026-09-28 11:00:00Z])
      end)

      stub(Messaging.Chat.RepoMock, :list_messages, fn @channel_id, _opts ->
        {:ok, [edited_doc("msg-1", ~U[2026-09-28 12:30:00Z]) |> Map.drop(["edited_at"])]}
      end)

      stub(Messaging.Chat.RepoMock, :list_changes, fn _cid, _from, _limit ->
        {:ok, [edited_doc("msg-0", ~U[2026-09-28 12:20:00Z])]}
      end)

      assert {:ok, _reply, _socket} =
               subscribe_and_join(
                 join_socket("user-a"),
                 RoomChannel,
                 "channel:" <> @channel_id,
                 %{
                   "last_message_id" => "msg-0",
                   "changes_since" => "2026-09-28T12:00:00Z"
                 }
               )

      assert_push "missed_messages", %{"messages" => [%{"id" => "msg-1"}]}
      assert_push "changed_messages", %{"messages" => [%{"id" => "msg-0"}]}
    end

    test "a timestamp that does not parse is rejected at join" do
      for bad <- ["ayer", "2026-13-45T99:00:00Z", "", 12_345, %{"$gt" => ""}, ["x"]] do
        assert {:error, %{error: %{code: "INVALID_CURSOR"}}} = join_since(bad)
      end
    end

    test "if the changes query fails the channel stops so the client rejoins" do
      stub(Messaging.Chat.RepoMock, :list_changes, fn _cid, _from, _limit ->
        {:error, :timeout}
      end)

      socket = %Phoenix.Socket{assigns: %{channel_id: @channel_id}}

      assert {:stop, :catch_up_failed, ^socket} =
               RoomChannel.handle_info({:after_join, nil, ~U[2026-09-28 12:00:00Z]}, socket)
    end
  end
end
