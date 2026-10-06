defmodule Messaging.Chat.MentionsFlowTest do
  use ExUnit.Case, async: true
  import Mox

  alias Messaging.Chat
  alias Messaging.Chat.{Conversation, Mentions, Message, UserMention}
  alias Phoenix.Socket.Broadcast

  setup :verify_on_exit!

  @channel_id "chan-mentions"
  @server_id "srv-mentions"
  @author "author-1"
  @raw_jwt "a.jwt.token"
  @role "9b1e2c3d-4e5f-4a6b-8c7d-0e1f2a3b4c5d"

  defp text_channel_doc,
    do: %{"_id" => @channel_id, "server_id" => @server_id, "name" => "general", "kind" => "text"}

  # Unique per test: PubSub topics are global and tests run concurrently.
  defp user(name), do: "#{name}-#{System.unique_integer([:positive])}"

  defp listen(user_id), do: MessagingWeb.Endpoint.subscribe("user:" <> user_id)

  defp allow_send do
    expect(Messaging.Chat.RepoMock, :get_channel, fn @channel_id -> text_channel_doc() end)

    expect(Messaging.Chat.PermissionsClientMock, :can_send_messages?, fn @server_id,
                                                                         @author,
                                                                         @raw_jwt ->
      {:ok, true}
    end)
  end

  defp resolution(fields), do: struct!(Mentions.none(), fields)

  defp expect_resolve(expected_query, result) do
    expect(Messaging.Chat.MentionsClientMock, :resolve, fn @server_id,
                                                           @channel_id,
                                                           query,
                                                           @raw_jwt ->
      assert query == expected_query
      result
    end)
  end

  defp send_message(content),
    do:
      Chat.send_message(%{
        channel_id: @channel_id,
        user_id: @author,
        content: content,
        raw_jwt: @raw_jwt
      })

  defp stored_doc(overrides) do
    Map.merge(
      %{
        "_id" => "msg-1",
        "channel_id" => @channel_id,
        "server_id" => @server_id,
        "user_id" => @author,
        "content" => "texto original",
        "inserted_at" => ~U[2026-10-06 12:00:00.000Z]
      },
      overrides
    )
  end

  describe "send_message/1" do
    test "CA1: a mentioned member gets a stored and a live highlighted notification" do
      ana = user("ana")
      listen(ana)
      allow_send()

      expect_resolve(
        %{user_ids: [ana], role_ids: [], everyone: false},
        {:ok, resolution(user_ids: [ana], recipient_ids: [ana])}
      )

      expect(Messaging.Chat.RepoMock, :insert_message, fn doc ->
        assert doc["mentions"] == [ana]
        assert doc["mention_roles"] == []
        assert doc["mention_everyone"] == false
        {:ok, doc}
      end)

      expect(Messaging.Chat.RepoMock, :insert_mentions, fn [doc] ->
        assert doc["user_id"] == ana
        assert doc["author_id"] == @author
        assert doc["channel_id"] == @channel_id
        assert doc["server_id"] == @server_id
        assert doc["read_at"] == nil
        assert doc["_id"] == UserMention.id(doc["message_id"], ana)
        {:ok, [ana]}
      end)

      assert {:ok, %Message{mentions: [^ana]} = message} = send_message("hola <@#{ana}>")

      assert_receive %Broadcast{
        topic: "user:" <> ^ana,
        event: "mention",
        payload: %{
          "server_id" => @server_id,
          "channel_id" => @channel_id,
          "message" => %{"mentions" => [^ana], "content" => content}
        }
      }

      assert content == message.content
    end

    test "CA2: a role mention notifies every holder servers returns" do
      [ana, bob] = [user("ana"), user("bob")]
      Enum.each([ana, bob], &listen/1)
      allow_send()

      expect_resolve(
        %{user_ids: [], role_ids: [@role], everyone: false},
        {:ok, resolution(role_ids: [@role], recipient_ids: [ana, bob])}
      )

      expect(Messaging.Chat.RepoMock, :insert_message, fn doc ->
        assert doc["mention_roles"] == [@role]
        {:ok, doc}
      end)

      expect(Messaging.Chat.RepoMock, :insert_mentions, fn docs ->
        {:ok, Enum.map(docs, & &1["user_id"])}
      end)

      assert {:ok, %Message{mention_roles: [@role]}} = send_message("<@&#{@role}> reunión")

      assert_receive %Broadcast{topic: "user:" <> ^ana, event: "mention"}
      assert_receive %Broadcast{topic: "user:" <> ^bob, event: "mention"}
    end

    test "CA3: @everyone notifies every member servers says can see the channel" do
      members = [user("ana"), user("bob"), user("caro")]
      Enum.each(members, &listen/1)
      allow_send()

      expect_resolve(
        %{user_ids: [], role_ids: [], everyone: true},
        {:ok, resolution(everyone: true, recipient_ids: members)}
      )

      expect(Messaging.Chat.RepoMock, :insert_message, fn doc ->
        assert doc["mention_everyone"] == true
        {:ok, doc}
      end)

      expect(Messaging.Chat.RepoMock, :insert_mentions, fn docs ->
        assert length(docs) == 3
        {:ok, Enum.map(docs, & &1["user_id"])}
      end)

      assert {:ok, %Message{mention_everyone: true}} = send_message("@everyone hay examen")

      for member <- members do
        assert_receive %Broadcast{topic: "user:" <> ^member, event: "mention"}
      end
    end

    test "CA4: @everyone without permission is plain text: the message goes out, nobody is pinged" do
      allow_send()

      # servers drops what the author can't mention (see mention_service)
      expect_resolve(%{user_ids: [], role_ids: [], everyone: true}, {:ok, Mentions.none()})

      expect(Messaging.Chat.RepoMock, :insert_message, fn doc ->
        refute Map.has_key?(doc, "mention_everyone")
        {:ok, doc}
      end)

      assert {:ok, %Message{content: "@everyone hola", mention_everyone: false, mentions: []}} =
               send_message("@everyone hola")

      refute_receive %Broadcast{event: "mention"}, 50
    end

    test "CA4 keeps the user mentions of the same message working" do
      ana = user("ana")
      listen(ana)
      allow_send()

      expect_resolve(
        %{user_ids: [ana], role_ids: [], everyone: true},
        {:ok, resolution(user_ids: [ana], recipient_ids: [ana])}
      )

      expect(Messaging.Chat.RepoMock, :insert_message, fn doc -> {:ok, doc} end)
      expect(Messaging.Chat.RepoMock, :insert_mentions, fn _docs -> {:ok, [ana]} end)

      assert {:ok, %Message{mentions: [^ana], mention_everyone: false}} =
               send_message("@everyone y <@#{ana}>")

      assert_receive %Broadcast{topic: "user:" <> ^ana, event: "mention"}
    end

    test "a message without mention tokens never asks servers" do
      allow_send()
      expect(Messaging.Chat.RepoMock, :insert_message, fn doc -> {:ok, doc} end)

      # No MentionsClientMock expectation: calling it would fail the test.
      assert {:ok, %Message{mentions: []}} = send_message("hola @ana, mail a@b.com")
    end

    test "if servers can't check the mentions, the message is not sent" do
      allow_send()

      expect(Messaging.Chat.MentionsClientMock, :resolve, fn _sid, _cid, _query, _jwt ->
        {:error, :mentions_unavailable}
      end)

      assert {:error, :mentions_unavailable} = send_message("<@ana> hola")
    end

    test "a mentioned member who can't see the channel is named but not notified" do
      allow_send()

      expect_resolve(
        %{user_ids: ["blind"], role_ids: [], everyone: false},
        {:ok, resolution(user_ids: ["blind"], recipient_ids: [])}
      )

      expect(Messaging.Chat.RepoMock, :insert_message, fn doc ->
        assert doc["mentions"] == ["blind"]
        {:ok, doc}
      end)

      # No insert_mentions expectation: nobody to notify.
      assert {:ok, %Message{mentions: ["blind"]}} = send_message("<@blind>")
    end

    test "if storing the notifications fails, the message stands and the live notice still goes out" do
      ana = user("ana")
      listen(ana)
      allow_send()

      expect_resolve(
        %{user_ids: [ana], role_ids: [], everyone: false},
        {:ok, resolution(user_ids: [ana], recipient_ids: [ana])}
      )

      expect(Messaging.Chat.RepoMock, :insert_message, fn doc -> {:ok, doc} end)
      expect(Messaging.Chat.RepoMock, :insert_mentions, fn _docs -> {:error, :timeout} end)

      assert {:ok, %Message{}} = send_message("<@#{ana}>")
      assert_receive %Broadcast{topic: "user:" <> ^ana, event: "mention"}
    end
  end

  describe "edit_message/1" do
    defp allow_edit(doc) do
      expect(Messaging.Chat.RepoMock, :get_channel, fn @channel_id -> text_channel_doc() end)

      expect(Messaging.Chat.PermissionsClientMock, :can_send_messages?, fn _sid, _uid, _jwt ->
        {:ok, true}
      end)

      expect(Messaging.Chat.RepoMock, :get_message, fn "msg-1" -> doc end)
    end

    defp edit(content),
      do:
        Chat.edit_message(%{
          channel_id: @channel_id,
          message_id: "msg-1",
          user_id: @author,
          content: content,
          raw_jwt: @raw_jwt
        })

    test "swapping who is mentioned forgets the old one and notifies only the new one" do
      [ana, bob] = [user("ana"), user("bob")]
      Enum.each([ana, bob], &listen/1)
      allow_edit(stored_doc(%{"content" => "<@#{ana}>", "mentions" => [ana]}))

      expect_resolve(
        %{user_ids: [bob], role_ids: [], everyone: false},
        {:ok, resolution(user_ids: [bob], recipient_ids: [bob])}
      )

      expect(Messaging.Chat.RepoMock, :update_message, fn "msg-1",
                                                          @channel_id,
                                                          @author,
                                                          content,
                                                          at,
                                                          fields ->
        assert fields == %{
                 "mentions" => [bob],
                 "mention_roles" => [],
                 "mention_everyone" => false
               }

        {:ok, stored_doc(Map.merge(fields, %{"content" => content, "edited_at" => at}))}
      end)

      expect(Messaging.Chat.RepoMock, :delete_mentions, fn "msg-1", [^bob] -> :ok end)

      expect(Messaging.Chat.RepoMock, :insert_mentions, fn [%{"user_id" => ^bob}] ->
        {:ok, [bob]}
      end)

      assert {:ok, %Message{mentions: [^bob]}, :updated} = edit("<@#{bob}>")

      assert_receive %Broadcast{topic: "user:" <> ^bob, event: "mention"}
      refute_receive %Broadcast{topic: "user:" <> ^ana, event: "mention"}, 50
    end

    test "an edit that keeps someone mentioned doesn't ping them again" do
      ana = user("ana")
      listen(ana)
      allow_edit(stored_doc(%{"content" => "<@#{ana}>", "mentions" => [ana]}))

      expect_resolve(
        %{user_ids: [ana], role_ids: [], everyone: false},
        {:ok, resolution(user_ids: [ana], recipient_ids: [ana])}
      )

      expect(Messaging.Chat.RepoMock, :update_message, fn _id, _cid, _uid, content, at, fields ->
        {:ok, stored_doc(Map.merge(fields, %{"content" => content, "edited_at" => at}))}
      end)

      expect(Messaging.Chat.RepoMock, :delete_mentions, fn "msg-1", [^ana] -> :ok end)
      # Already stored: the repo reports no new recipients.
      expect(Messaging.Chat.RepoMock, :insert_mentions, fn _docs -> {:ok, []} end)

      assert {:ok, _message, :updated} = edit("<@#{ana}> (corregido)")
      refute_receive %Broadcast{event: "mention"}, 50
    end

    test "removing every mention clears the stored ones and pings nobody" do
      ana = user("ana")
      allow_edit(stored_doc(%{"content" => "<@#{ana}>", "mentions" => [ana]}))

      expect(Messaging.Chat.RepoMock, :update_message, fn _id, _cid, _uid, content, at, fields ->
        assert fields["mentions"] == []
        {:ok, stored_doc(Map.merge(fields, %{"content" => content, "edited_at" => at}))}
      end)

      expect(Messaging.Chat.RepoMock, :delete_mentions, fn "msg-1", [] -> :ok end)

      assert {:ok, %Message{mentions: []}, :updated} = edit("ya no menciono a nadie")
    end

    test "the mentions are checked again: losing MENTION_EVERYONE turns an edited @everyone into text" do
      allow_edit(stored_doc(%{"content" => "aviso"}))
      expect_resolve(%{user_ids: [], role_ids: [], everyone: true}, {:ok, Mentions.none()})

      expect(Messaging.Chat.RepoMock, :update_message, fn _id, _cid, _uid, content, at, fields ->
        assert fields["mention_everyone"] == false
        {:ok, stored_doc(Map.merge(fields, %{"content" => content, "edited_at" => at}))}
      end)

      assert {:ok, %Message{mention_everyone: false}, :updated} = edit("aviso @everyone")
    end

    test "if servers can't check the new mentions, the edit is not applied" do
      allow_edit(stored_doc(%{"content" => "aviso"}))

      expect(Messaging.Chat.MentionsClientMock, :resolve, fn _sid, _cid, _query, _jwt ->
        {:error, :mentions_unavailable}
      end)

      assert {:error, :mentions_unavailable} = edit("aviso <@ana>")
    end
  end

  describe "delete_message/1" do
    test "deleting a message with mentions removes its notifications" do
      expect(Messaging.Chat.RepoMock, :get_channel, fn @channel_id -> text_channel_doc() end)

      expect(Messaging.Chat.PermissionsClientMock, :can_view_channel?, fn _sid, _uid, _jwt ->
        {:ok, true}
      end)

      expect(Messaging.Chat.RepoMock, :get_message, fn "msg-1" ->
        stored_doc(%{"mention_everyone" => true})
      end)

      expect(Messaging.Chat.RepoMock, :delete_message, fn "msg-1", @channel_id, at ->
        {:ok, stored_doc(%{"content" => "", "deleted_at" => at})}
      end)

      expect(Messaging.Chat.RepoMock, :delete_mentions, fn "msg-1", [] -> :ok end)

      assert {:ok, %Message{}} =
               Chat.delete_message(%{
                 channel_id: @channel_id,
                 message_id: "msg-1",
                 user_id: @author,
                 raw_jwt: @raw_jwt
               })
    end
  end

  describe "direct conversations" do
    test "tokens in a DM are plain text: servers is never asked" do
      dm = Conversation.new_doc(@author, "friend", DateTime.utc_now())

      expect(Messaging.Chat.RepoMock, :get_channel, fn _id -> dm end)
      stub(Messaging.Chat.RepoMock, :get_blocks, fn _ids -> {:ok, []} end)

      expect(Messaging.Chat.RepoMock, :get_message, fn "msg-1" ->
        stored_doc(%{"channel_id" => dm["_id"], "server_id" => nil})
      end)

      expect(Messaging.Chat.RepoMock, :update_message, fn _id, _cid, _uid, content, at, fields ->
        assert fields["mentions"] == []
        {:ok, stored_doc(%{"channel_id" => dm["_id"], "content" => content, "edited_at" => at})}
      end)

      assert {:ok, %Message{mentions: []}, :updated} =
               Chat.edit_message(%{
                 channel_id: dm["_id"],
                 message_id: "msg-1",
                 user_id: @author,
                 content: "<@friend> @everyone",
                 raw_jwt: @raw_jwt
               })
    end
  end

  describe "list_mentions/2" do
    test "returns the unread mentions with their message, newest first" do
      expect(Messaging.Chat.RepoMock, :list_unread_mentions, fn "ana", 50 ->
        {:ok,
         [
           %{
             "_id" => "msg-2:ana",
             "user_id" => "ana",
             "message_id" => "msg-2",
             "channel_id" => @channel_id,
             "server_id" => @server_id,
             "author_id" => @author,
             "inserted_at" => ~U[2026-10-06 12:01:00.000Z],
             "read_at" => nil
           },
           %{
             "_id" => "gone:ana",
             "user_id" => "ana",
             "message_id" => "gone",
             "channel_id" => @channel_id,
             "server_id" => @server_id,
             "author_id" => @author,
             "inserted_at" => ~U[2026-10-06 12:00:00.000Z],
             "read_at" => nil
           }
         ]}
      end)

      expect(Messaging.Chat.RepoMock, :get_messages, fn ["msg-2", "gone"] ->
        {:ok, [stored_doc(%{"_id" => "msg-2", "content" => "<@ana>", "mentions" => ["ana"]})]}
      end)

      assert {:ok, [first, second]} = Chat.list_mentions("ana")
      assert %UserMention{message_id: "msg-2", message: %Message{mentions: ["ana"]}} = first
      assert %UserMention{message_id: "gone", message: nil} = second
    end

    test "no unread mentions means no message lookup" do
      expect(Messaging.Chat.RepoMock, :list_unread_mentions, fn "ana", 10 -> {:ok, []} end)
      assert {:ok, []} = Chat.list_mentions("ana", limit: 10)
    end
  end

  describe "mark_mentions_read/2" do
    test "marks the user's mentions of an existing channel as read" do
      expect(Messaging.Chat.RepoMock, :get_channel, fn @channel_id -> text_channel_doc() end)

      expect(Messaging.Chat.RepoMock, :mark_mentions_read, fn "ana", @channel_id, at ->
        assert {_micro, 3} = at.microsecond
        :ok
      end)

      assert :ok = Chat.mark_mentions_read(@channel_id, "ana")
    end

    test "an unknown channel is not found" do
      expect(Messaging.Chat.RepoMock, :get_channel, fn "nope" -> nil end)
      assert {:error, :channel_not_found} = Chat.mark_mentions_read("nope", "ana")
    end
  end

  test "delete_member_mentions/2 drops a former member's mentions in that server" do
    expect(Messaging.Chat.RepoMock, :delete_member_mentions, fn @server_id, "ana" -> :ok end)
    assert :ok = Chat.delete_member_mentions(@server_id, "ana")
  end
end
