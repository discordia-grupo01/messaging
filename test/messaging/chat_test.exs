defmodule Messaging.ChatTest do
  use ExUnit.Case, async: true
  import Mox

  alias Messaging.Chat
  alias Messaging.Chat.Message

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
                                                          %DateTime{} = edited_at ->
        assert {_micro, 3} = edited_at.microsecond
        {:ok, stored_doc(%{"content" => "texto corregido", "edited_at" => edited_at})}
      end)

      assert {:ok, %Message{content: "texto corregido", edited_at: %DateTime{}}, :updated} =
               Chat.edit_message(edit_params())
    end

    test "the new content is trimmed like on send" do
      allow_edit()

      expect(Messaging.Chat.RepoMock, :update_message, fn _id, _cid, _uid, "con espacios", _at ->
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
                                                          _t ->
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

      expect(Messaging.Chat.RepoMock, :update_message, fn _id, _cid, _uid, ^exact, _at ->
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

      expect(Messaging.Chat.RepoMock, :update_message, fn _id, _cid, _uid, _c, _t ->
        {:ok, nil}
      end)

      assert {:error, :message_not_found} = Chat.edit_message(edit_params())
    end

    test "a repository failure on update is propagated" do
      allow_edit()

      expect(Messaging.Chat.RepoMock, :update_message, fn _id, _cid, _uid, _c, _t ->
        {:error, :timeout}
      end)

      assert {:error, :timeout} = Chat.edit_message(edit_params())
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

      assert {:ok, [%Message{id: "a", edited_at: %DateTime{}}, %Message{id: "b"}]} =
               Chat.list_changes(@channel_id, ~U[2026-09-28 12:00:00Z])
    end

    test "exactly the maximum is returned, one more is too many" do
      expect(Messaging.Chat.RepoMock, :list_changes, fn _cid, _from, 201 ->
        {:ok, for(i <- 1..200, do: changed_doc("m-#{i}"))}
      end)

      assert {:ok, messages} = Chat.list_changes(@channel_id, ~U[2026-09-28 12:00:00Z])
      assert length(messages) == 200

      expect(Messaging.Chat.RepoMock, :list_changes, fn _cid, _from, 201 ->
        {:ok, for(i <- 1..201, do: changed_doc("m-#{i}"))}
      end)

      assert {:error, :too_many_changes} =
               Chat.list_changes(@channel_id, ~U[2026-09-28 12:00:00Z])
    end

    test "nothing changed is an empty list" do
      expect(Messaging.Chat.RepoMock, :list_changes, fn _cid, _from, _limit -> {:ok, []} end)

      assert {:ok, []} = Chat.list_changes(@channel_id, ~U[2026-09-28 12:00:00Z])
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
