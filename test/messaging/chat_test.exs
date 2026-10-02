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
