defmodule MessagingWeb.UserChannelTest do
  use MessagingWeb.ChannelCase
  import Mox

  alias Messaging.AuthFixtures
  alias Messaging.Chat.Conversation
  alias MessagingWeb.{RoomChannel, UserChannel}

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    stub(Messaging.Chat.RepoMock, :get_blocks, fn _ids -> {:ok, []} end)
    :ok
  end

  @ana "11111111-1111-4111-8111-111111111111"
  @beto "22222222-2222-4222-8222-222222222222"
  @cami "33333333-3333-4333-8333-333333333333"

  defp socket_for(user_id) do
    stub(Messaging.Auth.TicketStoreMock, :take, fn _id ->
      {:ok, AuthFixtures.ticket_doc(user_id)}
    end)

    {:ok, socket} = connect(MessagingWeb.UserSocket, %{"ticket" => "a-ticket"})
    socket
  end

  defp join_own(user_id) do
    {:ok, _reply, socket} =
      subscribe_and_join(socket_for(user_id), UserChannel, "user:" <> user_id)

    socket
  end

  defp dm_id(a, b), do: Conversation.id(a, b)

  defp dm_doc(a, b) do
    %{
      "_id" => dm_id(a, b),
      "server_id" => nil,
      "name" => "",
      "kind" => "dm",
      "participants" => Enum.sort([a, b])
    }
  end

  defp stub_new_conversation(a, b) do
    id = dm_id(a, b)
    stub(Messaging.Chat.RepoMock, :get_channel, fn ^id -> nil end)
    stub(Messaging.Chat.UsersClientMock, :user_exists?, fn _id, _jwt -> {:ok, true} end)
    stub(Messaging.Chat.RepoMock, :ensure_conversation, fn _doc -> :ok end)
    stub(Messaging.Chat.RepoMock, :insert_message, fn doc -> {:ok, doc} end)
    stub(Messaging.Chat.RepoMock, :record_last_message, fn _, _, _, _ -> :ok end)
  end

  describe "join" do
    test "a user joins their own topic" do
      assert {:ok, _reply, _socket} =
               subscribe_and_join(socket_for(@ana), UserChannel, "user:" <> @ana)
    end

    test "nobody can listen to another user's topic" do
      assert {:error, %{error: %{code: "FORBIDDEN"}}} =
               subscribe_and_join(socket_for(@ana), UserChannel, "user:" <> @beto)
    end
  end

  describe "send_dm" do
    test "CA2: the first message creates the conversation and replies with its id and the message" do
      stub_new_conversation(@ana, @beto)
      ana = join_own(@ana)

      ref = push(ana, "send_dm", %{"to" => @beto, "content" => "hola Beto"})

      assert_reply ref, :ok, %{
        "conversation_id" => conversation_id,
        "message" => %{"content" => "hola Beto", "user_id" => @ana, "server_id" => nil}
      }

      assert conversation_id == dm_id(@ana, @beto)
    end

    test "CA1: the recipient is notified on their own topic even with no conversation open" do
      stub_new_conversation(@ana, @beto)
      ana = join_own(@ana)
      Phoenix.PubSub.subscribe(Messaging.PubSub, "user:" <> @beto)

      ref = push(ana, "send_dm", %{"to" => @beto, "content" => "hola Beto"})
      assert_reply ref, :ok

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "user:" <> @beto,
        event: "new_dm",
        payload: %{
          "conversation_id" => conversation_id,
          "partner_id" => @ana,
          "message" => %{"content" => "hola Beto", "user_id" => @ana}
        }
      }

      assert conversation_id == dm_id(@ana, @beto)
    end

    test "the sender's own topic is notified too, so their other tabs see it" do
      stub_new_conversation(@ana, @beto)
      ana = join_own(@ana)

      ref = push(ana, "send_dm", %{"to" => @beto, "content" => "hola"})
      assert_reply ref, :ok

      assert_push "new_dm",
                  %{"partner_id" => @beto, "message" => %{"content" => "hola"}} = notification

      refute Map.has_key?(notification, "participants")
    end

    test "who has the conversation open also gets new_message on its channel topic" do
      stub_new_conversation(@ana, @beto)
      id = dm_id(@ana, @beto)
      Phoenix.PubSub.subscribe(Messaging.PubSub, "channel:" <> id)
      ana = join_own(@ana)

      ref = push(ana, "send_dm", %{"to" => @beto, "content" => "hola"})
      assert_reply ref, :ok

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "channel:" <> ^id,
        event: "new_message",
        payload: %{"content" => "hola", "channel_id" => ^id}
      }
    end

    test "an existing conversation is continued without asking identify-service again" do
      id = dm_id(@ana, @beto)
      stub(Messaging.Chat.RepoMock, :get_channel, fn ^id -> dm_doc(@ana, @beto) end)
      stub(Messaging.Chat.RepoMock, :insert_message, fn doc -> {:ok, doc} end)
      stub(Messaging.Chat.RepoMock, :record_last_message, fn _, _, _, _ -> :ok end)
      ana = join_own(@ana)

      ref = push(ana, "send_dm", %{"to" => @beto, "content" => "otra vez"})

      assert_reply ref, :ok, %{"conversation_id" => ^id}
    end

    test "a recipient that does not exist is rejected" do
      id = dm_id(@ana, @cami)
      stub(Messaging.Chat.RepoMock, :get_channel, fn ^id -> nil end)
      stub(Messaging.Chat.UsersClientMock, :user_exists?, fn _id, _jwt -> {:ok, false} end)
      ana = join_own(@ana)

      ref = push(ana, "send_dm", %{"to" => @cami, "content" => "hola"})

      assert_reply ref, :error, %{error: %{code: "RECIPIENT_NOT_FOUND"}}
      refute_push "new_dm", _payload
    end

    test "identify-service being down is a clear error and the channel survives" do
      id = dm_id(@ana, @beto)
      stub(Messaging.Chat.RepoMock, :get_channel, fn ^id -> nil end)
      stub(Messaging.Chat.UsersClientMock, :user_exists?, fn _id, _jwt -> {:error, :timeout} end)
      ana = join_own(@ana)

      ref = push(ana, "send_dm", %{"to" => @beto, "content" => "hola"})
      assert_reply ref, :error, %{error: %{code: "USERS_UNAVAILABLE"}}

      stub_new_conversation(@ana, @beto)
      ref = push(ana, "send_dm", %{"to" => @beto, "content" => "ya anda"})
      assert_reply ref, :ok
    end

    test "CA3 of DM: a message to someone who blocked you is not delivered and nobody is notified" do
      stub(Messaging.Chat.RepoMock, :get_blocks, fn _ids ->
        {:ok, [%{"_id" => @beto <> ":" <> @ana}]}
      end)

      Phoenix.PubSub.subscribe(Messaging.PubSub, "user:" <> @beto)
      ana = join_own(@ana)

      ref = push(ana, "send_dm", %{"to" => @beto, "content" => "hola"})

      assert_reply ref, :error, %{error: %{code: "DM_NOT_DELIVERED"} = error}
      refute inspect(error) =~ "block"
      refute_receive %Phoenix.Socket.Broadcast{event: "new_dm"}, 100
      refute_push "new_dm", _payload
    end

    test "if you blocked them, you are told to unblock first" do
      stub(Messaging.Chat.RepoMock, :get_blocks, fn _ids ->
        {:ok, [%{"_id" => @ana <> ":" <> @beto}]}
      end)

      ana = join_own(@ana)

      ref = push(ana, "send_dm", %{"to" => @beto, "content" => "hola"})

      assert_reply ref, :error, %{error: %{code: "USER_BLOCKED"}}
    end

    test "CA3 of the block story: once unblocked, the message goes through again" do
      stub_new_conversation(@ana, @beto)
      ana = join_own(@ana)

      stub(Messaging.Chat.RepoMock, :get_blocks, fn _ids ->
        {:ok, [%{"_id" => @beto <> ":" <> @ana}]}
      end)

      ref = push(ana, "send_dm", %{"to" => @beto, "content" => "hola"})
      assert_reply ref, :error, %{error: %{code: "DM_NOT_DELIVERED"}}

      stub(Messaging.Chat.RepoMock, :get_blocks, fn _ids -> {:ok, []} end)

      ref = push(ana, "send_dm", %{"to" => @beto, "content" => "hola de nuevo"})
      assert_reply ref, :ok, %{"message" => %{"content" => "hola de nuevo"}}
    end

    test "you cannot message yourself" do
      ana = join_own(@ana)

      ref = push(ana, "send_dm", %{"to" => @ana, "content" => "hola yo"})

      assert_reply ref, :error, %{error: %{code: "CANNOT_MESSAGE_SELF"}}
    end

    test "empty and over-long content are rejected" do
      ana = join_own(@ana)

      ref = push(ana, "send_dm", %{"to" => @beto, "content" => "   "})
      assert_reply ref, :error, %{error: %{code: "EMPTY_CONTENT"}}

      too_long = String.duplicate("a", Messaging.Chat.max_message_length() + 1)
      ref = push(ana, "send_dm", %{"to" => @beto, "content" => too_long})
      assert_reply ref, :error, %{error: %{code: "MESSAGE_TOO_LONG"}}
    end

    test "malformed payloads get an error reply instead of crashing the channel" do
      ana = join_own(@ana)

      for payload <- [
            %{},
            %{"to" => @beto},
            %{"content" => "hola"},
            %{"to" => @beto, "content" => %{"a" => 1}},
            %{"to" => @beto, "content" => 5}
          ] do
        ref = push(ana, "send_dm", payload)
        assert_reply ref, :error, %{error: %{code: "INVALID_PAYLOAD"}}
      end

      for bad <- [%{"$ne" => "x"}, 5, "../me", "a.b"] do
        ref = push(ana, "send_dm", %{"to" => bad, "content" => "hola"})
        assert_reply ref, :error, %{error: %{code: code}}
        assert code in ["INVALID_PAYLOAD", "RECIPIENT_NOT_FOUND"]
      end

      stub_new_conversation(@ana, @beto)
      ref = push(ana, "send_dm", %{"to" => @beto, "content" => "sigue funcionando"})
      assert_reply ref, :ok
    end

    test "if the realtime broadcast fails the message is still saved and acknowledged" do
      stub_new_conversation(@ana, @beto)
      previous = Application.get_env(:messaging, :broadcaster)
      Application.put_env(:messaging, :broadcaster, Messaging.FailingBroadcaster)
      on_exit(fn -> Application.put_env(:messaging, :broadcaster, previous) end)
      ana = join_own(@ana)

      ref = push(ana, "send_dm", %{"to" => @beto, "content" => "hola"})

      assert_reply ref, :ok, %{"conversation_id" => _id}
    end
  end

  describe "what ends up in the logs" do
    import ExUnit.CaptureLog

    setup do
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)
    end

    test "a private message, its recipient and the ticket never reach the logs, even in debug" do
      stub_new_conversation(@ana, @beto)
      secret = "texto-privado-" <> Integer.to_string(System.unique_integer([:positive]))

      log =
        capture_log([level: :debug], fn ->
          ana = join_own(@ana)
          ref = push(ana, "send_dm", %{"to" => @beto, "content" => secret})
          assert_reply ref, :ok
          Process.sleep(50)
        end)

      refute log =~ secret
      refute log =~ "\"to\":\"" <> @beto

      entries = log |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

      assert Enum.any?(
               entries,
               &match?(
                 %{"message" => "channel_event", "event" => "send_dm", "level" => "debug"},
                 &1
               )
             )

      assert Enum.any?(entries, &match?(%{"message" => "socket_connected", "result" => "ok"}, &1))
      refute Enum.any?(entries, &(&1["message"] =~ "Parameters"))
    end

    test "every line the application writes is valid JSON" do
      stub_new_conversation(@ana, @beto)

      log =
        capture_log([level: :debug], fn ->
          ana = join_own(@ana)
          ref = push(ana, "send_dm", %{"to" => @beto, "content" => "hola"})
          assert_reply ref, :ok
          Process.sleep(50)
        end)

      lines = log |> String.split("\n", trim: true)
      assert lines != []

      for line <- lines,
          do: assert(%{"level" => _, "service" => "messaging"} = Jason.decode!(line))

      assert Enum.any?(lines, &(&1 =~ "message_sent"))
    end
  end

  describe "the conversation channel" do
    setup do
      id = dm_id(@ana, @beto)
      stub(Messaging.Chat.RepoMock, :get_channel, fn ^id -> dm_doc(@ana, @beto) end)
      {:ok, id: id}
    end

    test "a participant joins and a stranger is told the conversation does not exist", %{id: id} do
      assert {:ok, _reply, _socket} =
               subscribe_and_join(socket_for(@ana), RoomChannel, "channel:" <> id)

      assert {:error, %{error: %{code: "CHANNEL_NOT_FOUND"}}} =
               subscribe_and_join(socket_for(@cami), RoomChannel, "channel:" <> id)
    end

    test "new_message on a conversation is refused: DMs are sent with send_dm", %{id: id} do
      {:ok, _reply, socket} = subscribe_and_join(socket_for(@ana), RoomChannel, "channel:" <> id)

      ref = push(socket, "new_message", %{"content" => "hola"})

      assert_reply ref, :error, %{error: %{code: "CHANNEL_NOT_TEXT"}}
    end

    test "editing and deleting use the same events as in a server channel", %{id: id} do
      doc = %{
        "_id" => "msg-1",
        "channel_id" => id,
        "server_id" => nil,
        "user_id" => @ana,
        "content" => "original",
        "inserted_at" => ~U[2026-10-05 10:00:00Z]
      }

      stub(Messaging.Chat.RepoMock, :get_message, fn "msg-1" -> doc end)

      stub(Messaging.Chat.RepoMock, :update_message, fn "msg-1",
                                                        _cid,
                                                        _uid,
                                                        content,
                                                        at,
                                                        _mention_fields ->
        {:ok, Map.merge(doc, %{"content" => content, "edited_at" => at})}
      end)

      stub(Messaging.Chat.RepoMock, :delete_message, fn "msg-1", _cid, at ->
        {:ok, Map.merge(doc, %{"content" => "", "deleted_at" => at})}
      end)

      {:ok, _reply, ana} = subscribe_and_join(socket_for(@ana), RoomChannel, "channel:" <> id)

      ref = push(ana, "edit_message", %{"id" => "msg-1", "content" => "corregido"})
      assert_reply ref, :ok, %{"edited" => true, "server_id" => nil}
      assert_push "message_updated", %{"content" => "corregido"}

      ref = push(ana, "delete_message", %{"id" => "msg-1"})
      assert_reply ref, :ok
      assert_push "message_deleted", %{"id" => "msg-1", "server_id" => nil}
    end

    test "CA2 of the block story: the conversation is frozen, nothing can be edited or deleted",
         %{id: id} do
      doc = %{
        "_id" => "msg-1",
        "channel_id" => id,
        "server_id" => nil,
        "user_id" => @ana,
        "content" => "mio",
        "inserted_at" => ~U[2026-10-05 10:00:00Z]
      }

      stub(Messaging.Chat.RepoMock, :get_blocks, fn _ids ->
        {:ok, [%{"_id" => @beto <> ":" <> @ana}]}
      end)

      stub(Messaging.Chat.RepoMock, :get_message, fn "msg-1" -> doc end)

      {:ok, _reply, ana} = subscribe_and_join(socket_for(@ana), RoomChannel, "channel:" <> id)

      ref = push(ana, "edit_message", %{"id" => "msg-1", "content" => "cambiado"})
      assert_reply ref, :error, %{error: %{code: "FORBIDDEN"}}

      ref = push(ana, "delete_message", %{"id" => "msg-1"})
      assert_reply ref, :error, %{error: %{code: "FORBIDDEN"}}
      refute_push "message_deleted", _payload
    end

    test "the other participant cannot delete the author's message", %{id: id} do
      doc = %{
        "_id" => "msg-1",
        "channel_id" => id,
        "server_id" => nil,
        "user_id" => @ana,
        "content" => "mio",
        "inserted_at" => ~U[2026-10-05 10:00:00Z]
      }

      stub(Messaging.Chat.RepoMock, :get_message, fn "msg-1" -> doc end)
      {:ok, _reply, beto} = subscribe_and_join(socket_for(@beto), RoomChannel, "channel:" <> id)

      ref = push(beto, "delete_message", %{"id" => "msg-1"})
      assert_reply ref, :error, %{error: %{code: "MESSAGE_DELETE_DENIED"}}

      ref = push(beto, "edit_message", %{"id" => "msg-1", "content" => "robado"})
      assert_reply ref, :error, %{error: %{code: "NOT_MESSAGE_AUTHOR"}}
    end
  end
end
