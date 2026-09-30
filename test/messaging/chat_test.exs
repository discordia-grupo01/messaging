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
    test "returns messages and a next_cursor when the page is full" do
      docs =
        for i <- 1..2 do
          %{
            "_id" => "msg-#{i}",
            "channel_id" => @channel_id,
            "server_id" => @server_id,
            "user_id" => @user_id,
            "content" => "msg #{i}",
            "inserted_at" => ~U[2026-09-28 12:00:00Z]
          }
        end

      expect(Messaging.Chat.RepoMock, :list_messages, fn @channel_id, opts ->
        assert Keyword.get(opts, :limit) == 2
        {:ok, docs}
      end)

      assert {:ok, messages, "msg-2"} = Chat.list_messages(@channel_id, limit: 2)
      assert length(messages) == 2
    end

    test "next_cursor is nil when the page isn't full" do
      expect(Messaging.Chat.RepoMock, :list_messages, fn @channel_id, _opts -> {:ok, []} end)

      assert {:ok, [], nil} = Chat.list_messages(@channel_id, limit: 50)
    end

    test "an unknown before cursor is an error" do
      expect(Messaging.Chat.RepoMock, :get_message, fn "does-not-exist" -> nil end)

      assert {:error, :invalid_cursor} = Chat.list_messages(@channel_id, before: "does-not-exist")
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
