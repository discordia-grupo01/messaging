defmodule Messaging.Chat.WordFilterFlowTest do
  use ExUnit.Case, async: true
  import Mox

  alias Messaging.Chat
  alias Messaging.Chat.{Conversation, PermissionsStoreMock, RepoMock}

  setup :verify_on_exit!

  setup do
    Messaging.OutboxHelper.stub_outbox()
    Messaging.SuspensionHelper.stub_active()
    :ok
  end

  @channel_id "chan-1"
  @server_id "srv-1"
  @user_id "user-1"

  setup do
    stub(RepoMock, :get_clock, fn _key -> nil end)

    stub(RepoMock, :get_channel, fn @channel_id ->
      %{"_id" => @channel_id, "server_id" => @server_id, "name" => "general", "kind" => "text"}
    end)

    stub(RepoMock, :get_word_filter, fn @server_id -> {:ok, ["tonto", "no sirve"]} end)
    stub(PermissionsStoreMock, :can_send_messages?, fn _channel, _uid -> {:ok, true} end)
    :ok
  end

  defp send_params(content),
    do: %{channel_id: @channel_id, user_id: @user_id, content: content}

  describe "send_message/1" do
    test "CA1: a message with a banned word is not sent and says which ones" do
      expect(RepoMock, :insert_message, 0, fn doc -> {:ok, doc} end)

      assert {:error, {:banned_word, ["tonto", "no sirve"]}} =
               Chat.send_message(send_params("sos TÓNTO, esto no sirve"))
    end

    test "a clean message goes out as always" do
      expect(RepoMock, :insert_message, fn doc -> {:ok, doc} end)

      assert {:ok, %{content: "qué buena película"}} =
               Chat.send_message(send_params("qué buena película"))
    end

    test "a server without a list filters nothing" do
      stub(RepoMock, :get_word_filter, fn @server_id -> {:ok, []} end)
      expect(RepoMock, :insert_message, fn doc -> {:ok, doc} end)

      assert {:ok, _message} = Chat.send_message(send_params("tonto"))
    end

    test "nobody is exempt: the owner's messages are filtered too" do
      expect(RepoMock, :insert_message, 0, fn doc -> {:ok, doc} end)

      assert {:error, {:banned_word, ["tonto"]}} =
               Chat.send_message(%{send_params("tonto") | user_id: "owner-1"})
    end

    test "someone who can't write learns that first, never the list" do
      stub(PermissionsStoreMock, :can_send_messages?, fn _channel, _uid -> {:ok, false} end)
      expect(RepoMock, :get_word_filter, 0, fn _server_id -> {:ok, ["tonto"]} end)

      assert {:error, :forbidden} = Chat.send_message(send_params("tonto"))
    end

    test "if the list can't be read, the message is not sent" do
      stub(RepoMock, :get_word_filter, fn _server_id -> {:error, :timeout} end)
      expect(RepoMock, :insert_message, 0, fn doc -> {:ok, doc} end)

      assert {:error, :timeout} = Chat.send_message(send_params("hola"))
    end
  end

  describe "edit_message/1" do
    defp stored(content) do
      %{
        "_id" => "msg-1",
        "channel_id" => @channel_id,
        "server_id" => @server_id,
        "user_id" => @user_id,
        "content" => content,
        "inserted_at" => ~U[2026-10-10 12:00:00.000Z]
      }
    end

    defp edit_params(content),
      do: %{channel_id: @channel_id, message_id: "msg-1", user_id: @user_id, content: content}

    test "editing in a banned word is blocked too, so the filter can't be dodged" do
      stub(RepoMock, :get_message, fn "msg-1" -> stored("hola") end)
      expect(RepoMock, :update_message, 0, fn _id, _c, _u, _content, _at, _m -> {:ok, nil} end)

      assert {:error, {:banned_word, ["tonto"]}} = Chat.edit_message(edit_params("hola tonto"))
    end

    test "CA2: a message sent before the word was banned is left alone if the edit changes nothing" do
      stub(RepoMock, :get_message, fn "msg-1" -> stored("viejo tonto") end)
      expect(RepoMock, :get_word_filter, 0, fn _server_id -> {:ok, ["tonto"]} end)

      assert {:ok, %{content: "viejo tonto"}, :unchanged} =
               Chat.edit_message(edit_params("viejo tonto"))
    end
  end

  describe "direct messages" do
    test "the filter belongs to servers: a DM is never checked" do
      sender = "user-1"
      recipient = "user-2"
      dm_id = Conversation.id(sender, recipient)

      stub(RepoMock, :get_blocks, fn _ids -> {:ok, []} end)

      stub(RepoMock, :get_channel, fn ^dm_id ->
        %{
          "_id" => dm_id,
          "server_id" => nil,
          "name" => "",
          "kind" => "dm",
          "participants" => [sender, recipient]
        }
      end)

      stub(RepoMock, :record_last_message, fn _c, _m, _u, _a -> :ok end)
      expect(RepoMock, :get_word_filter, 0, fn _server_id -> {:ok, ["tonto"]} end)
      expect(RepoMock, :insert_message, fn doc -> {:ok, doc} end)

      assert {:ok, _channel, %{content: "tonto"}} =
               Chat.send_direct_message(%{
                 sender_id: sender,
                 recipient_id: recipient,
                 content: "tonto"
               })
    end
  end
end
