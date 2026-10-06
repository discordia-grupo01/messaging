defmodule Messaging.ChatTest do
  use ExUnit.Case, async: true
  import Mox

  alias Messaging.Chat
  alias Messaging.Chat.{ChannelCache, Conversation, Message}

  setup :verify_on_exit!

  @channel_id "chan-1"
  @server_id "srv-1"
  @user_id "user-1"
  @raw_jwt "a.jwt.token"

  defp text_channel_doc,
    do: %{"_id" => @channel_id, "server_id" => @server_id, "name" => "general", "kind" => "text"}

  defp send_params(overrides \\ %{}) do
    Map.merge(
      %{channel_id: @channel_id, user_id: @user_id, content: "hola", raw_jwt: @raw_jwt},
      overrides
    )
  end

  describe "send_message/1" do
    test "persists and returns the message on success" do
      expect(Messaging.Chat.RepoMock, :get_channel, fn @channel_id -> text_channel_doc() end)

      expect(Messaging.Chat.PermissionsClientMock, :can_send_messages?, fn @server_id,
                                                                           @user_id,
                                                                           @raw_jwt ->
        {:ok, true}
      end)

      expect(Messaging.Chat.RepoMock, :insert_message, fn doc -> {:ok, doc} end)

      assert {:ok, %Message{content: "hola", channel_id: @channel_id, user_id: @user_id}} =
               Chat.send_message(send_params())
    end

    test "stores the timestamp with millisecond precision, as Mongo does" do
      expect(Messaging.Chat.RepoMock, :get_channel, fn @channel_id -> text_channel_doc() end)

      expect(Messaging.Chat.PermissionsClientMock, :can_send_messages?, fn _, _, _ ->
        {:ok, true}
      end)

      expect(Messaging.Chat.RepoMock, :insert_message, fn doc -> {:ok, doc} end)

      assert {:ok, %Message{inserted_at: %DateTime{microsecond: {_, 3}}}} =
               Chat.send_message(send_params())
    end

    test "ids grow with every message so same-millisecond messages keep their send order" do
      stub(Messaging.Chat.RepoMock, :get_channel, fn @channel_id -> text_channel_doc() end)

      stub(Messaging.Chat.PermissionsClientMock, :can_send_messages?, fn _, _, _ ->
        {:ok, true}
      end)

      stub(Messaging.Chat.RepoMock, :insert_message, fn doc -> {:ok, doc} end)

      ids =
        for i <- 1..300 do
          {:ok, message} = Chat.send_message(send_params(%{content: "m#{i}"}))
          message.id
        end

      assert ids == Enum.sort(ids)
    end

    test "rejects empty content" do
      expect(Messaging.Chat.RepoMock, :get_channel, fn @channel_id -> text_channel_doc() end)

      assert {:error, :empty_content} = Chat.send_message(send_params(%{content: "   "}))
    end

    test "rejects when the permissions check says no" do
      expect(Messaging.Chat.RepoMock, :get_channel, fn @channel_id -> text_channel_doc() end)

      expect(Messaging.Chat.PermissionsClientMock, :can_send_messages?, fn @server_id,
                                                                           @user_id,
                                                                           @raw_jwt ->
        {:ok, false}
      end)

      assert {:error, :forbidden} = Chat.send_message(send_params())
    end

    test "rejects a message over the max length" do
      expect(Messaging.Chat.RepoMock, :get_channel, fn @channel_id -> text_channel_doc() end)
      too_long = String.duplicate("a", Chat.max_message_length() + 1)

      assert {:error, :message_too_long} = Chat.send_message(send_params(%{content: too_long}))
    end

    test "accepts a message at exactly the max length" do
      expect(Messaging.Chat.RepoMock, :get_channel, fn @channel_id -> text_channel_doc() end)

      expect(Messaging.Chat.PermissionsClientMock, :can_send_messages?, fn _sid, _uid, _jwt ->
        {:ok, true}
      end)

      expect(Messaging.Chat.RepoMock, :insert_message, fn doc -> {:ok, doc} end)
      exactly_max = String.duplicate("a", Chat.max_message_length())

      assert {:ok, _message} = Chat.send_message(send_params(%{content: exactly_max}))
    end

    test "returns channel_not_found when the channel doesn't exist locally" do
      expect(Messaging.Chat.RepoMock, :get_channel, fn @channel_id -> nil end)

      assert {:error, :channel_not_found} = Chat.send_message(send_params())
    end

    test "returns channel_not_text for a voice channel" do
      expect(Messaging.Chat.RepoMock, :get_channel, fn @channel_id ->
        %{"_id" => @channel_id, "server_id" => @server_id, "name" => "voice-1", "kind" => "voice"}
      end)

      assert {:error, :channel_not_text} = Chat.send_message(send_params())
    end

    test "propagates a repo insert failure instead of pretending success" do
      expect(Messaging.Chat.RepoMock, :get_channel, fn @channel_id -> text_channel_doc() end)

      expect(Messaging.Chat.PermissionsClientMock, :can_send_messages?, fn _sid, _uid, _jwt ->
        {:ok, true}
      end)

      expect(Messaging.Chat.RepoMock, :insert_message, fn _doc -> {:error, :timeout} end)

      assert {:error, :timeout} = Chat.send_message(send_params())
    end
  end

  describe "edit_message/1" do
    defp stored_doc(overrides \\ %{}) do
      Map.merge(
        %{
          "_id" => "msg-1",
          "channel_id" => @channel_id,
          "server_id" => @server_id,
          "user_id" => @user_id,
          "content" => "texto original",
          "inserted_at" => ~U[2026-09-28 12:00:00Z]
        },
        overrides
      )
    end

    defp edit_params(overrides \\ %{}) do
      Map.merge(
        %{
          channel_id: @channel_id,
          message_id: "msg-1",
          user_id: @user_id,
          content: "texto corregido",
          raw_jwt: @raw_jwt
        },
        overrides
      )
    end

    defp allow_edit(doc \\ stored_doc()) do
      expect(Messaging.Chat.RepoMock, :get_channel, fn @channel_id -> text_channel_doc() end)

      expect(Messaging.Chat.PermissionsClientMock, :can_send_messages?, fn @server_id,
                                                                           @user_id,
                                                                           @raw_jwt ->
        {:ok, true}
      end)

      expect(Messaging.Chat.RepoMock, :get_message, fn "msg-1" -> doc end)
    end

    test "the author changes the content and the message comes back marked as edited" do
      allow_edit()

      expect(Messaging.Chat.RepoMock, :update_message, fn "msg-1",
                                                          @channel_id,
                                                          @user_id,
                                                          "texto corregido",
                                                          %DateTime{} = edited_at,
                                                          _mention_fields ->
        assert {_micro, 3} = edited_at.microsecond
        {:ok, stored_doc(%{"content" => "texto corregido", "edited_at" => edited_at})}
      end)

      assert {:ok, %Message{content: "texto corregido", edited_at: %DateTime{}}, :updated} =
               Chat.edit_message(edit_params())
    end

    test "the new content is trimmed like on send" do
      allow_edit()

      expect(Messaging.Chat.RepoMock, :update_message, fn _id,
                                                          _cid,
                                                          _uid,
                                                          "con espacios",
                                                          _at,
                                                          _mention_fields ->
        {:ok, stored_doc(%{"content" => "con espacios", "edited_at" => DateTime.utc_now()})}
      end)

      assert {:ok, %Message{content: "con espacios"}, :updated} =
               Chat.edit_message(edit_params(%{content: "   con espacios \n"}))
    end

    test "the original timestamp and author are untouched: only the filter pins them" do
      allow_edit()

      expect(Messaging.Chat.RepoMock, :update_message, fn "msg-1",
                                                          @channel_id,
                                                          @user_id,
                                                          _c,
                                                          _t,
                                                          _mention_fields ->
        {:ok, stored_doc(%{"content" => "texto corregido", "edited_at" => DateTime.utc_now()})}
      end)

      assert {:ok, %Message{inserted_at: ~U[2026-09-28 12:00:00Z], user_id: @user_id}, :updated} =
               Chat.edit_message(edit_params())
    end

    test "an edit that leaves the content identical changes nothing and is not marked as edited" do
      allow_edit()

      assert {:ok, %Message{content: "texto original", edited_at: nil}, :unchanged} =
               Chat.edit_message(edit_params(%{content: "  texto original "}))
    end

    test "someone who is not the author is rejected without touching the message" do
      allow_edit(stored_doc(%{"user_id" => "another-user"}))

      assert {:error, :not_message_author} = Chat.edit_message(edit_params())
    end

    test "the author check comes before content validation" do
      allow_edit(stored_doc(%{"user_id" => "another-user"}))

      assert {:error, :not_message_author} = Chat.edit_message(edit_params(%{content: "   "}))
    end

    test "rejects empty content" do
      allow_edit()

      assert {:error, :empty_content} = Chat.edit_message(edit_params(%{content: "  "}))
    end

    test "rejects content over the limit and accepts exactly the limit" do
      allow_edit()

      assert {:error, :message_too_long} =
               Chat.edit_message(
                 edit_params(%{content: String.duplicate("a", Chat.max_message_length() + 1)})
               )

      allow_edit()
      exact = String.duplicate("a", Chat.max_message_length())

      expect(Messaging.Chat.RepoMock, :update_message, fn _id,
                                                          _cid,
                                                          _uid,
                                                          ^exact,
                                                          _at,
                                                          _mention_fields ->
        {:ok, stored_doc(%{"content" => exact, "edited_at" => DateTime.utc_now()})}
      end)

      assert {:ok, %Message{}, :updated} = Chat.edit_message(edit_params(%{content: exact}))
    end

    test "a message that does not exist" do
      expect(Messaging.Chat.RepoMock, :get_channel, fn @channel_id -> text_channel_doc() end)

      expect(Messaging.Chat.PermissionsClientMock, :can_send_messages?, fn _, _, _ ->
        {:ok, true}
      end)

      expect(Messaging.Chat.RepoMock, :get_message, fn "msg-1" -> nil end)

      assert {:error, :message_not_found} = Chat.edit_message(edit_params())
    end

    test "a message that belongs to another channel is reported as not found" do
      allow_edit(stored_doc(%{"channel_id" => "other-channel"}))

      assert {:error, :message_not_found} = Chat.edit_message(edit_params())
    end

    test "a deleted message cannot be edited" do
      allow_edit(stored_doc(%{"content" => "", "deleted_at" => ~U[2026-09-28 12:05:00Z]}))

      assert {:error, :message_not_found} = Chat.edit_message(edit_params())
    end

    test "an id that is not a string never reaches the repository" do
      bad_ids = [%{"$ne" => "x"}, nil, 123, ["msg-1"]]
      calls = length(bad_ids)

      expect(Messaging.Chat.RepoMock, :get_channel, calls, fn @channel_id ->
        text_channel_doc()
      end)

      expect(Messaging.Chat.PermissionsClientMock, :can_send_messages?, calls, fn _, _, _ ->
        {:ok, true}
      end)

      for bad <- bad_ids do
        assert {:error, :message_not_found} = Chat.edit_message(edit_params(%{message_id: bad}))
      end
    end

    test "someone who can no longer write in the channel cannot edit" do
      expect(Messaging.Chat.RepoMock, :get_channel, fn @channel_id -> text_channel_doc() end)

      expect(Messaging.Chat.PermissionsClientMock, :can_send_messages?, fn _, _, _ ->
        {:ok, false}
      end)

      assert {:error, :forbidden} = Chat.edit_message(edit_params())
    end

    test "a failing permissions check is propagated" do
      expect(Messaging.Chat.RepoMock, :get_channel, fn @channel_id -> text_channel_doc() end)

      expect(Messaging.Chat.PermissionsClientMock, :can_send_messages?, fn _, _, _ ->
        {:error, :timeout}
      end)

      assert {:error, :timeout} = Chat.edit_message(edit_params())
    end

    test "an unknown channel and a voice channel are rejected" do
      expect(Messaging.Chat.RepoMock, :get_channel, fn @channel_id -> nil end)
      assert {:error, :channel_not_found} = Chat.edit_message(edit_params())

      expect(Messaging.Chat.RepoMock, :get_channel, fn @channel_id ->
        %{"_id" => @channel_id, "server_id" => @server_id, "name" => "voz", "kind" => "voice"}
      end)

      assert {:error, :channel_not_text} = Chat.edit_message(edit_params())
    end

    test "the message vanishing between the read and the write is reported as not found" do
      allow_edit()

      expect(Messaging.Chat.RepoMock, :update_message, fn _id,
                                                          _cid,
                                                          _uid,
                                                          _c,
                                                          _t,
                                                          _mention_fields ->
        {:ok, nil}
      end)

      assert {:error, :message_not_found} = Chat.edit_message(edit_params())
    end

    test "a repository failure on update is propagated" do
      allow_edit()

      expect(Messaging.Chat.RepoMock, :update_message, fn _id,
                                                          _cid,
                                                          _uid,
                                                          _c,
                                                          _t,
                                                          _mention_fields ->
        {:error, :timeout}
      end)

      assert {:error, :timeout} = Chat.edit_message(edit_params())
    end
  end

  describe "delete_message/1" do
    @moderator_id "moderator-1"

    defp delete_params(overrides \\ %{}) do
      Map.merge(
        %{channel_id: @channel_id, message_id: "msg-1", user_id: @user_id, raw_jwt: @raw_jwt},
        overrides
      )
    end

    defp allow_view(user_id) do
      expect(Messaging.Chat.RepoMock, :get_channel, fn @channel_id -> text_channel_doc() end)

      expect(Messaging.Chat.PermissionsClientMock, :can_view_channel?, fn @server_id,
                                                                          ^user_id,
                                                                          @raw_jwt ->
        {:ok, true}
      end)
    end

    defp allow_delete_lookup(doc, user_id \\ @user_id) do
      allow_view(user_id)
      expect(Messaging.Chat.RepoMock, :get_message, fn "msg-1" -> doc end)
    end

    defp expect_tombstone do
      expect(Messaging.Chat.RepoMock, :delete_message, fn "msg-1", @channel_id, deleted_at ->
        assert {_micro, 3} = deleted_at.microsecond

        {:ok,
         stored_doc(%{"content" => "", "deleted_at" => deleted_at, "changed_at" => deleted_at})}
      end)
    end

    test "CA1: the author deletes their own message without needing any moderation permission" do
      allow_delete_lookup(stored_doc())
      expect_tombstone()

      assert {:ok, %Message{id: "msg-1", content: "", deleted_at: %DateTime{}}} =
               Chat.delete_message(delete_params())
    end

    test "CA2: a member with MANAGE_MESSAGES deletes someone else's message" do
      allow_delete_lookup(stored_doc(), @moderator_id)

      expect(Messaging.Chat.PermissionsClientMock, :can_manage_messages?, fn @server_id,
                                                                             @moderator_id,
                                                                             @raw_jwt ->
        {:ok, true}
      end)

      expect_tombstone()

      assert {:ok, %Message{user_id: @user_id, deleted_at: %DateTime{}}} =
               Chat.delete_message(delete_params(%{user_id: @moderator_id}))
    end

    test "CA3: someone who is neither the author nor a moderator is not allowed" do
      allow_delete_lookup(stored_doc(), "intruder")

      expect(Messaging.Chat.PermissionsClientMock, :can_manage_messages?, fn _, "intruder", _ ->
        {:ok, false}
      end)

      assert {:error, :message_delete_denied} =
               Chat.delete_message(delete_params(%{user_id: "intruder"}))
    end

    test "the author is never asked for MANAGE_MESSAGES" do
      allow_delete_lookup(stored_doc())
      expect_tombstone()

      assert {:ok, %Message{}} = Chat.delete_message(delete_params())
    end

    test "someone who cannot view the channel (an author who left included) is rejected before the message is read" do
      expect(Messaging.Chat.RepoMock, :get_channel, fn @channel_id -> text_channel_doc() end)

      expect(Messaging.Chat.PermissionsClientMock, :can_view_channel?, fn _, _, _ ->
        {:ok, false}
      end)

      assert {:error, :forbidden} = Chat.delete_message(delete_params())
    end

    test "a message that does not exist, is in another channel, or is already deleted is not found" do
      allow_delete_lookup(nil)
      assert {:error, :message_not_found} = Chat.delete_message(delete_params())

      allow_delete_lookup(stored_doc(%{"channel_id" => "other-channel"}))
      assert {:error, :message_not_found} = Chat.delete_message(delete_params())

      allow_delete_lookup(
        stored_doc(%{"content" => "", "deleted_at" => ~U[2026-09-28 12:05:00Z]})
      )

      assert {:error, :message_not_found} = Chat.delete_message(delete_params())
    end

    test "an id that is not a string never reaches the repository" do
      bad_ids = [%{"$ne" => "x"}, nil, 123, ["msg-1"]]
      calls = length(bad_ids)

      expect(Messaging.Chat.RepoMock, :get_channel, calls, fn @channel_id ->
        text_channel_doc()
      end)

      expect(Messaging.Chat.PermissionsClientMock, :can_view_channel?, calls, fn _, _, _ ->
        {:ok, true}
      end)

      for bad <- bad_ids do
        assert {:error, :message_not_found} =
                 Chat.delete_message(delete_params(%{message_id: bad}))
      end
    end

    test "an unknown channel and a voice channel are rejected" do
      expect(Messaging.Chat.RepoMock, :get_channel, fn @channel_id -> nil end)
      assert {:error, :channel_not_found} = Chat.delete_message(delete_params())

      expect(Messaging.Chat.RepoMock, :get_channel, fn @channel_id ->
        %{"_id" => @channel_id, "server_id" => @server_id, "name" => "voz", "kind" => "voice"}
      end)

      assert {:error, :channel_not_text} = Chat.delete_message(delete_params())
    end

    test "a failing permissions check is propagated, for the view and the moderation lookups" do
      expect(Messaging.Chat.RepoMock, :get_channel, fn @channel_id -> text_channel_doc() end)

      expect(Messaging.Chat.PermissionsClientMock, :can_view_channel?, fn _, _, _ ->
        {:error, :timeout}
      end)

      assert {:error, :timeout} = Chat.delete_message(delete_params())

      allow_delete_lookup(stored_doc(), "intruder")

      expect(Messaging.Chat.PermissionsClientMock, :can_manage_messages?, fn _, _, _ ->
        {:error, :timeout}
      end)

      assert {:error, :timeout} = Chat.delete_message(delete_params(%{user_id: "intruder"}))
    end

    test "the message being deleted by someone else between the read and the write is not found" do
      allow_delete_lookup(stored_doc())
      expect(Messaging.Chat.RepoMock, :delete_message, fn _id, _cid, _at -> {:ok, nil} end)

      assert {:error, :message_not_found} = Chat.delete_message(delete_params())
    end

    test "a repository failure on delete is propagated" do
      allow_delete_lookup(stored_doc())

      expect(Messaging.Chat.RepoMock, :delete_message, fn _id, _cid, _at -> {:error, :timeout} end)

      assert {:error, :timeout} = Chat.delete_message(delete_params())
    end
  end

  describe "direct conversations" do
    @sender "user-1"
    @recipient "user-2"

    setup do
      stub(Messaging.Chat.RepoMock, :get_blocks, fn _ids -> {:ok, []} end)
      :ok
    end

    defp dm_id, do: Conversation.id(@sender, @recipient)

    defp dm_doc(overrides \\ %{}) do
      Map.merge(
        %{
          "_id" => dm_id(),
          "server_id" => nil,
          "name" => "",
          "kind" => "dm",
          "participants" => [@sender, @recipient]
        },
        overrides
      )
    end

    defp dm_params(overrides \\ %{}) do
      Map.merge(
        %{sender_id: @sender, recipient_id: @recipient, content: "hola", raw_jwt: @raw_jwt},
        overrides
      )
    end

    defp expect_message_stored do
      expect(Messaging.Chat.RepoMock, :insert_message, fn doc ->
        assert doc["channel_id"] == dm_id()
        assert doc["server_id"] == nil
        assert doc["user_id"] == @sender
        {:ok, doc}
      end)

      expect(Messaging.Chat.RepoMock, :record_last_message, fn channel_id, _id, @sender, at ->
        assert channel_id == dm_id()
        assert %DateTime{} = at
        :ok
      end)
    end

    test "CA2: the first message creates the conversation after checking the recipient exists" do
      expect(Messaging.Chat.RepoMock, :get_channel, fn id ->
        assert id == dm_id()
        nil
      end)

      expect(Messaging.Chat.UsersClientMock, :user_exists?, fn @recipient, @raw_jwt ->
        {:ok, true}
      end)

      expect(Messaging.Chat.RepoMock, :ensure_conversation, fn doc ->
        assert doc["_id"] == dm_id()
        assert doc["kind"] == "dm"
        assert doc["participants"] == [@sender, @recipient]
        :ok
      end)

      expect_message_stored()

      assert {:ok, %ChannelCache{channel_id: channel_id, kind: "dm", server_id: nil},
              %Message{} = message} = Chat.send_direct_message(dm_params())

      assert channel_id == dm_id()

      assert %Message{content: "hola", user_id: @sender, server_id: nil, channel_id: ^channel_id} =
               message
    end

    test "CA1: a second message continues the conversation without asking about the recipient again" do
      expect(Messaging.Chat.RepoMock, :get_channel, fn _id -> dm_doc() end)
      expect_message_stored()

      assert {:ok, %ChannelCache{participants: [@sender, @recipient]}, %Message{}} =
               Chat.send_direct_message(dm_params())
    end

    test "the conversation is the same whoever writes first" do
      expect(Messaging.Chat.RepoMock, :get_channel, fn id ->
        assert id == dm_id()
        dm_doc()
      end)

      expect(Messaging.Chat.RepoMock, :insert_message, fn doc ->
        assert doc["user_id"] == @recipient
        {:ok, doc}
      end)

      expect(Messaging.Chat.RepoMock, :record_last_message, fn _id, _mid, @recipient, _at ->
        :ok
      end)

      assert {:ok, %ChannelCache{channel_id: channel_id}, _message} =
               Chat.send_direct_message(
                 dm_params(%{sender_id: @recipient, recipient_id: @sender})
               )

      assert channel_id == dm_id()
    end

    test "the content is trimmed and validated like in any channel" do
      assert {:error, :empty_content} = Chat.send_direct_message(dm_params(%{content: "   "}))

      too_long = String.duplicate("a", Chat.max_message_length() + 1)

      assert {:error, :message_too_long} =
               Chat.send_direct_message(dm_params(%{content: too_long}))

      expect(Messaging.Chat.RepoMock, :get_channel, fn _id -> dm_doc() end)

      expect(Messaging.Chat.RepoMock, :insert_message, fn doc ->
        assert doc["content"] == "con espacios"
        {:ok, doc}
      end)

      expect(Messaging.Chat.RepoMock, :record_last_message, fn _, _, _, _ -> :ok end)

      assert {:ok, _channel, %Message{content: "con espacios"}} =
               Chat.send_direct_message(dm_params(%{content: "  con espacios \n"}))
    end

    test "CA3 of DM: a blocked sender's message is not delivered: nothing is stored or created" do
      expect(Messaging.Chat.RepoMock, :get_blocks, fn _ids ->
        {:ok, [%{"_id" => @recipient <> ":" <> @sender}]}
      end)

      assert {:error, :dm_not_delivered} = Chat.send_direct_message(dm_params())
    end

    test "the sender who blocked the recipient cannot write to them either" do
      expect(Messaging.Chat.RepoMock, :get_blocks, fn _ids ->
        {:ok, [%{"_id" => @sender <> ":" <> @recipient}]}
      end)

      assert {:error, :user_blocked} = Chat.send_direct_message(dm_params())
    end

    test "the block is checked before identify-service is asked about a brand-new conversation" do
      expect(Messaging.Chat.RepoMock, :get_blocks, fn _ids ->
        {:ok, [%{"_id" => @recipient <> ":" <> @sender}]}
      end)

      assert {:error, :dm_not_delivered} = Chat.send_direct_message(dm_params())
    end

    test "if the block lookup fails the message is not sent" do
      expect(Messaging.Chat.RepoMock, :get_blocks, fn _ids -> {:error, :timeout} end)

      assert {:error, :timeout} = Chat.send_direct_message(dm_params())
    end

    test "when blocked, editing an old message in the conversation is refused too" do
      expect(Messaging.Chat.RepoMock, :get_channel, fn _id -> dm_doc() end)

      expect(Messaging.Chat.RepoMock, :get_blocks, fn _ids ->
        {:ok, [%{"_id" => @recipient <> ":" <> @sender}]}
      end)

      assert {:error, :forbidden} =
               Chat.edit_message(edit_params(%{channel_id: dm_id(), user_id: @sender}))
    end

    test "when blocked, deleting an old message is refused too: the history is kept as it was" do
      expect(Messaging.Chat.RepoMock, :get_channel, fn _id -> dm_doc() end)

      expect(Messaging.Chat.RepoMock, :get_blocks, fn _ids ->
        {:ok, [%{"_id" => @recipient <> ":" <> @sender}]}
      end)

      assert {:error, :forbidden} =
               Chat.delete_message(%{
                 channel_id: dm_id(),
                 message_id: "msg-1",
                 user_id: @sender,
                 raw_jwt: @raw_jwt
               })
    end

    test "the one who blocked cannot delete either, until they unblock" do
      expect(Messaging.Chat.RepoMock, :get_channel, fn _id -> dm_doc() end)

      expect(Messaging.Chat.RepoMock, :get_blocks, fn _ids ->
        {:ok, [%{"_id" => @recipient <> ":" <> @sender}]}
      end)

      assert {:error, :forbidden} =
               Chat.delete_message(%{
                 channel_id: dm_id(),
                 message_id: "msg-1",
                 user_id: @recipient,
                 raw_jwt: @raw_jwt
               })
    end

    test "a failing block lookup stops the deletion instead of allowing it" do
      expect(Messaging.Chat.RepoMock, :get_channel, fn _id -> dm_doc() end)
      expect(Messaging.Chat.RepoMock, :get_blocks, fn _ids -> {:error, :timeout} end)

      assert {:error, :timeout} =
               Chat.delete_message(%{
                 channel_id: dm_id(),
                 message_id: "msg-1",
                 user_id: @sender,
                 raw_jwt: @raw_jwt
               })
    end

    test "CA2: the history of a blocked conversation is still readable" do
      expect(Messaging.Chat.RepoMock, :list_messages, fn _id, _opts -> {:ok, []} end)

      assert {:ok, [], nil} = Chat.list_messages(dm_id())
    end

    test "you cannot message yourself, and nothing is read or written" do
      assert {:error, :cannot_message_self} =
               Chat.send_direct_message(dm_params(%{recipient_id: @sender}))
    end

    test "a recipient id that is not a plain identifier never reaches the services" do
      for bad <- ["../me", "a.b", "a$b", "", nil, 123, %{"$ne" => "x"}, String.duplicate("a", 65)] do
        assert {:error, :recipient_not_found} =
                 Chat.send_direct_message(dm_params(%{recipient_id: bad}))
      end
    end

    test "a recipient that does not exist creates nothing" do
      expect(Messaging.Chat.RepoMock, :get_channel, fn _id -> nil end)

      expect(Messaging.Chat.UsersClientMock, :user_exists?, fn _id, _jwt -> {:ok, false} end)

      assert {:error, :recipient_not_found} = Chat.send_direct_message(dm_params())
    end

    test "if identify-service cannot be reached the error is a clear 'unavailable', not a crash" do
      expect(Messaging.Chat.RepoMock, :get_channel, fn _id -> nil end)

      expect(Messaging.Chat.UsersClientMock, :user_exists?, fn _id, _jwt ->
        {:error, {:unexpected_status, 500}}
      end)

      assert {:error, :users_unavailable} = Chat.send_direct_message(dm_params())
    end

    test "a failure creating the conversation is propagated and no message is stored" do
      expect(Messaging.Chat.RepoMock, :get_channel, fn _id -> nil end)
      expect(Messaging.Chat.UsersClientMock, :user_exists?, fn _id, _jwt -> {:ok, true} end)
      expect(Messaging.Chat.RepoMock, :ensure_conversation, fn _doc -> {:error, :timeout} end)

      assert {:error, :timeout} = Chat.send_direct_message(dm_params())
    end

    test "a failure reading the conversation is propagated" do
      expect(Messaging.Chat.RepoMock, :get_channel, fn _id -> {:error, :timeout} end)

      assert {:error, :timeout} = Chat.send_direct_message(dm_params())
    end

    test "a failure storing the message is propagated and the conversation is not updated" do
      expect(Messaging.Chat.RepoMock, :get_channel, fn _id -> dm_doc() end)
      expect(Messaging.Chat.RepoMock, :insert_message, fn _doc -> {:error, :timeout} end)

      assert {:error, :timeout} = Chat.send_direct_message(dm_params())
    end

    test "if only the conversation update fails the message is still delivered" do
      expect(Messaging.Chat.RepoMock, :get_channel, fn _id -> dm_doc() end)
      expect(Messaging.Chat.RepoMock, :insert_message, fn doc -> {:ok, doc} end)

      expect(Messaging.Chat.RepoMock, :record_last_message, fn _, _, _, _ ->
        {:error, :timeout}
      end)

      assert {:ok, _channel, %Message{content: "hola"}} = Chat.send_direct_message(dm_params())
    end

    test "the existing channel send refuses a direct conversation: DMs have their own door" do
      expect(Messaging.Chat.RepoMock, :get_channel, fn _id -> dm_doc() end)

      assert {:error, :channel_not_text} =
               Chat.send_message(%{
                 channel_id: dm_id(),
                 user_id: @sender,
                 content: "hola",
                 raw_jwt: @raw_jwt
               })
    end

    test "joining or reading a direct conversation: participants yes, strangers get 'not found'" do
      stub(Messaging.Chat.RepoMock, :get_channel, fn _id -> dm_doc() end)

      assert {:ok, %ChannelCache{kind: "dm"} = channel} = Chat.channel_exists?(dm_id())
      assert {:ok, true} = Chat.can_view_channel?(channel, @sender, @raw_jwt)
      assert {:ok, true} = Chat.can_view_channel?(channel, @recipient, @raw_jwt)
      assert {:error, :channel_not_found} = Chat.can_view_channel?(channel, "intruder", @raw_jwt)
    end

    test "history of a direct conversation uses the same pagination" do
      expect(Messaging.Chat.RepoMock, :list_messages, fn id, opts ->
        assert id == dm_id()
        assert opts[:limit] == 51
        {:ok, []}
      end)

      assert {:ok, [], nil} = Chat.list_messages(dm_id())
    end

    test "the author edits a message in a direct conversation without asking servers" do
      expect(Messaging.Chat.RepoMock, :get_channel, fn _id -> dm_doc() end)

      expect(Messaging.Chat.RepoMock, :get_message, fn "msg-1" ->
        stored_doc(%{"channel_id" => dm_id(), "server_id" => nil})
      end)

      expect(Messaging.Chat.RepoMock, :update_message, fn "msg-1",
                                                          _cid,
                                                          @user_id,
                                                          "corregido",
                                                          at,
                                                          _mention_fields ->
        {:ok,
         stored_doc(%{
           "channel_id" => dm_id(),
           "server_id" => nil,
           "content" => "corregido",
           "edited_at" => at
         })}
      end)

      assert {:ok, %Message{content: "corregido", server_id: nil}, :updated} =
               Chat.edit_message(
                 edit_params(%{channel_id: dm_id(), message_id: "msg-1", content: "corregido"})
               )
    end

    test "a stranger cannot edit in a direct conversation" do
      expect(Messaging.Chat.RepoMock, :get_channel, fn _id -> dm_doc() end)

      assert {:error, :channel_not_found} =
               Chat.edit_message(edit_params(%{channel_id: dm_id(), user_id: "intruder"}))
    end

    test "the author deletes in a direct conversation, and the other participant cannot" do
      stub(Messaging.Chat.RepoMock, :get_channel, fn _id -> dm_doc() end)

      stub(Messaging.Chat.RepoMock, :get_message, fn "msg-1" ->
        stored_doc(%{"channel_id" => dm_id(), "server_id" => nil})
      end)

      expect(Messaging.Chat.RepoMock, :delete_message, fn "msg-1", _cid, at ->
        {:ok,
         stored_doc(%{
           "channel_id" => dm_id(),
           "server_id" => nil,
           "content" => "",
           "deleted_at" => at
         })}
      end)

      assert {:ok, %Message{deleted_at: %DateTime{}}} =
               Chat.delete_message(%{
                 channel_id: dm_id(),
                 message_id: "msg-1",
                 user_id: @user_id,
                 raw_jwt: @raw_jwt
               })

      assert {:error, :message_delete_denied} =
               Chat.delete_message(%{
                 channel_id: dm_id(),
                 message_id: "msg-1",
                 user_id: @recipient,
                 raw_jwt: @raw_jwt
               })

      assert {:error, :channel_not_found} =
               Chat.delete_message(%{
                 channel_id: dm_id(),
                 message_id: "msg-1",
                 user_id: "intruder",
                 raw_jwt: @raw_jwt
               })
    end
  end

  describe "list_conversations/2" do
    setup do
      stub(Messaging.Chat.RepoMock, :get_blocks, fn _ids -> {:ok, []} end)
      :ok
    end

    defp conversation_doc(id, partner, last_id, at, extra \\ %{}) do
      Map.merge(
        %{
          "_id" => id,
          "kind" => "dm",
          "participants" => Enum.sort([@user_id, partner]),
          "last_message_id" => last_id,
          "last_message_user_id" => partner,
          "last_message_at" => at
        },
        extra
      )
    end

    defp last_doc(id, channel_id, content) do
      stored_doc(%{
        "_id" => id,
        "channel_id" => channel_id,
        "server_id" => nil,
        "user_id" => "x",
        "content" => content
      })
    end

    test "returns each conversation with its last message, in the order the repo gives" do
      expect(Messaging.Chat.RepoMock, :list_conversations, fn @user_id, 50 ->
        {:ok,
         [
           conversation_doc("dm-b", "user-b", "m-2", ~U[2026-10-05 12:00:00Z]),
           conversation_doc("dm-a", "user-a", "m-1", ~U[2026-10-05 10:00:00Z])
         ]}
      end)

      expect(Messaging.Chat.RepoMock, :get_messages, fn ids ->
        assert Enum.sort(ids) == ["m-1", "m-2"]
        {:ok, [last_doc("m-1", "dm-a", "primero"), last_doc("m-2", "dm-b", "segundo")]}
      end)

      assert {:ok,
              [
                %Conversation{
                  id: "dm-b",
                  last_message: %Message{content: "segundo"}
                },
                %Conversation{
                  id: "dm-a",
                  last_message: %Message{content: "primero"}
                }
              ]} = Chat.list_conversations(@user_id)
    end

    test "a last message that was deleted comes back as nil" do
      expect(Messaging.Chat.RepoMock, :list_conversations, fn _uid, _limit ->
        {:ok, [conversation_doc("dm-a", "user-a", "m-1", ~U[2026-10-05 10:00:00Z])]}
      end)

      expect(Messaging.Chat.RepoMock, :get_messages, fn _ids -> {:ok, []} end)

      assert {:ok, [%Conversation{last_message: nil}]} = Chat.list_conversations(@user_id)
    end

    test "blocked_by_me says which partners I blocked, in a single extra query" do
      expect(Messaging.Chat.RepoMock, :list_conversations, fn _uid, _limit ->
        {:ok,
         [
           conversation_doc("dm-a", "user-a", "m-1", ~U[2026-10-05 10:00:00Z]),
           conversation_doc("dm-b", "user-b", "m-2", ~U[2026-10-05 09:00:00Z])
         ]}
      end)

      expect(Messaging.Chat.RepoMock, :get_messages, fn _ids -> {:ok, []} end)

      expect(Messaging.Chat.RepoMock, :get_blocks, fn ids ->
        assert Enum.sort(ids) == [@user_id <> ":user-a", @user_id <> ":user-b"]
        {:ok, [%{"_id" => @user_id <> ":user-b", "blocked_id" => "user-b"}]}
      end)

      assert {:ok,
              [
                %Conversation{id: "dm-a", blocked_by_me: false},
                %Conversation{id: "dm-b", blocked_by_me: true}
              ]} = Chat.list_conversations(@user_id)
    end

    test "no conversations means no second query" do
      expect(Messaging.Chat.RepoMock, :list_conversations, fn _uid, _limit -> {:ok, []} end)

      assert {:ok, []} = Chat.list_conversations(@user_id)
    end

    test "the limit is clamped like in the history" do
      expect(Messaging.Chat.RepoMock, :list_conversations, fn _uid, 100 -> {:ok, []} end)
      assert {:ok, []} = Chat.list_conversations(@user_id, limit: 100)

      expect(Messaging.Chat.RepoMock, :list_conversations, fn _uid, 50 -> {:ok, []} end)
      assert {:ok, []} = Chat.list_conversations(@user_id, limit: 1_000_000)
    end

    test "a repository failure is propagated" do
      expect(Messaging.Chat.RepoMock, :list_conversations, fn _uid, _limit ->
        {:error, :timeout}
      end)

      assert {:error, :timeout} = Chat.list_conversations(@user_id)

      expect(Messaging.Chat.RepoMock, :list_conversations, fn _uid, _limit ->
        {:ok, [conversation_doc("dm-a", "user-a", "m-1", ~U[2026-10-05 10:00:00Z])]}
      end)

      expect(Messaging.Chat.RepoMock, :get_messages, fn _ids -> {:error, :timeout} end)
      assert {:error, :timeout} = Chat.list_conversations(@user_id)
    end
  end

  describe "mark_read/2" do
    test "marks everything up to the conversation's last message as read" do
      at = ~U[2026-10-05 12:00:00Z]

      expect(Messaging.Chat.RepoMock, :get_channel, fn "dm-1" ->
        %{
          "_id" => "dm-1",
          "kind" => "dm",
          "participants" => [@user_id, "user-2"],
          "last_message_at" => at
        }
      end)

      expect(Messaging.Chat.RepoMock, :mark_read, fn "dm-1", @user_id, ^at -> :ok end)

      assert :ok = Chat.mark_read("dm-1", @user_id)
    end

    test "a conversation without messages has nothing to mark" do
      expect(Messaging.Chat.RepoMock, :get_channel, fn "dm-1" ->
        %{"_id" => "dm-1", "kind" => "dm", "participants" => [@user_id, "user-2"]}
      end)

      assert :ok = Chat.mark_read("dm-1", @user_id)
    end

    test "a stranger, a server channel and a missing conversation are all 'not found'" do
      expect(Messaging.Chat.RepoMock, :get_channel, fn _ ->
        %{"_id" => "dm-1", "kind" => "dm", "participants" => ["a", "b"]}
      end)

      assert {:error, :channel_not_found} = Chat.mark_read("dm-1", @user_id)

      expect(Messaging.Chat.RepoMock, :get_channel, fn _ -> text_channel_doc() end)
      assert {:error, :channel_not_found} = Chat.mark_read(@channel_id, @user_id)

      expect(Messaging.Chat.RepoMock, :get_channel, fn _ -> nil end)
      assert {:error, :channel_not_found} = Chat.mark_read("ghost", @user_id)
    end

    test "a repository failure is propagated" do
      expect(Messaging.Chat.RepoMock, :get_channel, fn _ -> {:error, :timeout} end)
      assert {:error, :timeout} = Chat.mark_read("dm-1", @user_id)
    end
  end

  describe "list_messages/2" do
    defp doc(id, at, channel_id \\ @channel_id),
      do: %{
        "_id" => id,
        "channel_id" => channel_id,
        "server_id" => @server_id,
        "user_id" => @user_id,
        "content" => "msg #{id}",
        "inserted_at" => at
      }

    test "without cursor returns the latest page in chronological order" do
      expect(Messaging.Chat.RepoMock, :list_messages, fn @channel_id, opts ->
        assert opts[:limit] == 3
        assert opts[:before] == nil and opts[:after] == nil
        {:ok, [doc("c", ~U[2026-09-28 12:00:03Z]), doc("b", ~U[2026-09-28 12:00:02Z])]}
      end)

      assert {:ok, [%Message{id: "b"}, %Message{id: "c"}], nil} =
               Chat.list_messages(@channel_id, limit: 2)
    end

    test "a full page returns the oldest id as cursor for the next older page" do
      expect(Messaging.Chat.RepoMock, :list_messages, fn @channel_id, _opts ->
        {:ok,
         [
           doc("c", ~U[2026-09-28 12:00:03Z]),
           doc("b", ~U[2026-09-28 12:00:02Z]),
           doc("a", ~U[2026-09-28 12:00:01Z])
         ]}
      end)

      assert {:ok, [%Message{id: "b"}, %Message{id: "c"}], "b"} =
               Chat.list_messages(@channel_id, limit: 2)
    end

    test "an exactly full last page has no cursor" do
      expect(Messaging.Chat.RepoMock, :list_messages, fn @channel_id, _opts ->
        {:ok, [doc("b", ~U[2026-09-28 12:00:02Z]), doc("a", ~U[2026-09-28 12:00:01Z])]}
      end)

      assert {:ok, [_, _], nil} = Chat.list_messages(@channel_id, limit: 2)
    end

    test "before passes the cursor's timestamp and id to the repo" do
      at = ~U[2026-09-28 12:00:02Z]
      expect(Messaging.Chat.RepoMock, :get_message, fn "b" -> doc("b", at) end)

      expect(Messaging.Chat.RepoMock, :list_messages, fn @channel_id, opts ->
        assert opts[:before] == {at, "b"}
        {:ok, []}
      end)

      assert {:ok, [], nil} = Chat.list_messages(@channel_id, before: "b")
    end

    test "after keeps the repo's ascending order and returns the newest id as cursor" do
      at = ~U[2026-09-28 12:00:01Z]
      expect(Messaging.Chat.RepoMock, :get_message, fn "a" -> doc("a", at) end)

      expect(Messaging.Chat.RepoMock, :list_messages, fn @channel_id, opts ->
        assert opts[:after] == {at, "a"}

        {:ok,
         [
           doc("b", ~U[2026-09-28 12:00:02Z]),
           doc("c", ~U[2026-09-28 12:00:03Z]),
           doc("d", ~U[2026-09-28 12:00:04Z])
         ]}
      end)

      assert {:ok, [%Message{id: "b"}, %Message{id: "c"}], "c"} =
               Chat.list_messages(@channel_id, after: "a", limit: 2)
    end

    test "limit is clamped to the allowed range" do
      expect(Messaging.Chat.RepoMock, :list_messages, fn @channel_id, opts ->
        assert opts[:limit] == 101
        {:ok, []}
      end)

      assert {:ok, [], nil} = Chat.list_messages(@channel_id, limit: 100)

      expect(Messaging.Chat.RepoMock, :list_messages, fn @channel_id, opts ->
        assert opts[:limit] == 51
        {:ok, []}
      end)

      assert {:ok, [], nil} = Chat.list_messages(@channel_id, limit: 100_000)
    end

    test "an unknown cursor is an error" do
      expect(Messaging.Chat.RepoMock, :get_message, fn "does-not-exist" -> nil end)

      assert {:error, :invalid_cursor} = Chat.list_messages(@channel_id, before: "does-not-exist")
    end

    test "a cursor from another channel is an error" do
      expect(Messaging.Chat.RepoMock, :get_message, fn "x" ->
        doc("x", ~U[2026-09-28 12:00:00Z], "other-channel")
      end)

      assert {:error, :invalid_cursor} = Chat.list_messages(@channel_id, after: "x")
    end

    test "a cursor lookup failure is an invalid cursor" do
      expect(Messaging.Chat.RepoMock, :get_message, fn "x" -> {:error, :timeout} end)

      assert {:error, :invalid_cursor} = Chat.list_messages(@channel_id, after: "x")
    end

    test "a non-string cursor is rejected without touching the repo" do
      assert {:error, :invalid_cursor} = Chat.list_messages(@channel_id, before: %{"$ne" => "x"})
    end

    test "before and after together are rejected" do
      assert {:error, :invalid_cursor} = Chat.list_messages(@channel_id, before: "a", after: "b")
    end

    test "a repo failure is propagated" do
      expect(Messaging.Chat.RepoMock, :list_messages, fn @channel_id, _opts ->
        {:error, :timeout}
      end)

      assert {:error, :timeout} = Chat.list_messages(@channel_id)
    end
  end

  describe "can_view_channel?/3" do
    test "asks the permissions client about VIEW_CHANNELS for the channel's server" do
      expect(Messaging.Chat.PermissionsClientMock, :can_view_channel?, fn @server_id,
                                                                          @user_id,
                                                                          @raw_jwt ->
        {:ok, true}
      end)

      channel = %Messaging.Chat.ChannelCache{
        channel_id: @channel_id,
        server_id: @server_id,
        name: "general",
        kind: "text"
      }

      assert {:ok, true} = Chat.can_view_channel?(channel, @user_id, @raw_jwt)
    end
  end

  describe "list_changes/2" do
    defp changed_doc(id) do
      %{
        "_id" => id,
        "channel_id" => @channel_id,
        "server_id" => @server_id,
        "user_id" => @user_id,
        "content" => "editado #{id}",
        "inserted_at" => ~U[2026-09-28 10:00:00Z],
        "edited_at" => ~U[2026-09-28 12:01:00Z],
        "changed_at" => ~U[2026-09-28 12:01:00Z]
      }
    end

    test "asks the repo for changes a few seconds before the cursor, to absorb clock skew" do
      expect(Messaging.Chat.RepoMock, :list_changes, fn @channel_id, from, limit ->
        assert DateTime.compare(from, ~U[2026-09-28 11:59:55Z]) == :eq
        assert limit == 201
        {:ok, [changed_doc("a"), changed_doc("b")]}
      end)

      assert {:ok, [%Message{id: "a", edited_at: %DateTime{}}, %Message{id: "b"}], []} =
               Chat.list_changes(@channel_id, ~U[2026-09-28 12:00:00Z])
    end

    test "deleted messages come back as ids, apart from the edited ones" do
      tombstone =
        changed_doc("gone")
        |> Map.merge(%{"content" => "", "deleted_at" => ~U[2026-09-28 12:02:00Z]})

      expect(Messaging.Chat.RepoMock, :list_changes, fn _cid, _from, _limit ->
        {:ok, [changed_doc("a"), tombstone, changed_doc("b")]}
      end)

      assert {:ok, [%Message{id: "a"}, %Message{id: "b"}], ["gone"]} =
               Chat.list_changes(@channel_id, ~U[2026-09-28 12:00:00Z])
    end

    test "exactly the maximum is returned, one more is too many" do
      expect(Messaging.Chat.RepoMock, :list_changes, fn _cid, _from, 201 ->
        {:ok, for(i <- 1..200, do: changed_doc("m-#{i}"))}
      end)

      assert {:ok, messages, []} = Chat.list_changes(@channel_id, ~U[2026-09-28 12:00:00Z])
      assert length(messages) == 200

      expect(Messaging.Chat.RepoMock, :list_changes, fn _cid, _from, 201 ->
        {:ok, for(i <- 1..201, do: changed_doc("m-#{i}"))}
      end)

      assert {:error, :too_many_changes} =
               Chat.list_changes(@channel_id, ~U[2026-09-28 12:00:00Z])
    end

    test "nothing changed is an empty list" do
      expect(Messaging.Chat.RepoMock, :list_changes, fn _cid, _from, _limit -> {:ok, []} end)

      assert {:ok, [], []} = Chat.list_changes(@channel_id, ~U[2026-09-28 12:00:00Z])
    end

    test "a repo failure is propagated" do
      expect(Messaging.Chat.RepoMock, :list_changes, fn _cid, _from, _limit ->
        {:error, :timeout}
      end)

      assert {:error, :timeout} = Chat.list_changes(@channel_id, ~U[2026-09-28 12:00:00Z])
    end

    test "server_time/0 is an ISO 8601 UTC timestamp with millisecond precision" do
      assert Chat.server_time() =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/
    end
  end

  describe "channel read-model writes" do
    test "upsert_channel/1 delegates to the repo" do
      channel = %Messaging.Chat.ChannelCache{
        channel_id: @channel_id,
        server_id: @server_id,
        name: "general",
        kind: "text"
      }

      expect(Messaging.Chat.RepoMock, :upsert_channel, fn %{
                                                            "_id" => @channel_id,
                                                            "kind" => "text"
                                                          } ->
        :ok
      end)

      assert :ok = Chat.upsert_channel(channel)
    end

    test "delete_channel/1 delegates to the repo" do
      expect(Messaging.Chat.RepoMock, :delete_channel, fn @channel_id -> :ok end)

      assert :ok = Chat.delete_channel(@channel_id)
    end
  end

  describe "delete_server_data/2" do
    test "delegates to the repo with the server and its channel ids" do
      expect(Messaging.Chat.RepoMock, :delete_server_data, fn "srv-1", ["chan-1", "chan-2"] ->
        :ok
      end)

      assert :ok = Chat.delete_server_data("srv-1", ["chan-1", "chan-2"])
    end

    test "propagates a repo failure" do
      expect(Messaging.Chat.RepoMock, :delete_server_data, fn _server_id, _channel_ids ->
        {:error, :timeout}
      end)

      assert {:error, :timeout} = Chat.delete_server_data("srv-1", [])
    end
  end

  describe "mongo_ready?/0" do
    test "true when the repo pings successfully" do
      expect(Messaging.Chat.RepoMock, :ping, fn -> :ok end)
      assert Chat.mongo_ready?()
    end

    test "false when the repo ping fails" do
      expect(Messaging.Chat.RepoMock, :ping, fn -> {:error, :timeout} end)
      refute Chat.mongo_ready?()
    end
  end
end
