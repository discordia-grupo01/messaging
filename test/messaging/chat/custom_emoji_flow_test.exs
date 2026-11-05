defmodule Messaging.Chat.CustomEmojiFlowTest do
  use ExUnit.Case, async: true
  import Mox

  alias Messaging.Chat
  alias Messaging.Chat.{Conversation, Message, RepoMock, PermissionsStoreMock}

  setup :verify_on_exit!

  @channel_id "chan-1"
  @server_id "11111111-1111-4111-8111-111111111111"
  @other_server "22222222-2222-4222-8222-222222222222"
  @user_id "user-1"
  @recipient "user-2"
  @id "2f4e6a8c-1b3d-4f5a-9c7e-8d6b4a2c0e1f"
  @gif_id "3f4e6a8c-1b3d-4f5a-9c7e-8d6b4a2c0e1f"
  @static "<:party:#{@id}>"
  @animated "<a:dance:#{@gif_id}>"

  setup do
    Messaging.OutboxHelper.stub_outbox()
    Messaging.SuspensionHelper.stub_active()
    stub(RepoMock, :get_word_filter, fn _server -> {:ok, []} end)
    stub(RepoMock, :get_clock, fn _key -> nil end)
    stub(RepoMock, :get_channel, fn @channel_id -> channel_doc() end)
    stub(RepoMock, :insert_message, fn doc -> {:ok, doc} end)
    stub(RepoMock, :get_message, fn "msg-1" -> message_doc("hola") end)
    stub(RepoMock, :get_member, fn _server, _user -> %{"role_ids" => []} end)
    stub(RepoMock, :premium?, fn _user -> false end)
    stub(RepoMock, :reaction_emojis, fn "msg-1" -> {:ok, []} end)
    stub(RepoMock, :count_reactions, fn "msg-1", _emoji -> {:ok, 1} end)
    stub(RepoMock, :touch_message, fn "msg-1", _at -> :ok end)
    stub(RepoMock, :list_reactions, fn _ids -> {:ok, []} end)
    stub(PermissionsStoreMock, :can_send_messages?, fn _channel, _user -> {:ok, true} end)
    stub(PermissionsStoreMock, :can_add_reactions?, fn _channel, _user -> {:ok, true} end)
    stub(PermissionsStoreMock, :can_view_channel?, fn _channel, _user -> {:ok, true} end)
    :ok
  end

  defp channel_doc,
    do: %{"_id" => @channel_id, "server_id" => @server_id, "name" => "general", "kind" => "text"}

  defp message_doc(content) do
    %{
      "_id" => "msg-1",
      "channel_id" => @channel_id,
      "server_id" => @server_id,
      "user_id" => @user_id,
      "content" => content,
      "inserted_at" => ~U[2026-11-05 12:00:00.000Z]
    }
  end

  defp static_doc(server_id \\ @server_id, overrides \\ %{}) do
    Map.merge(
      %{"_id" => @id, "server_id" => server_id, "name" => "party", "animated" => false},
      overrides
    )
  end

  defp gif_doc,
    do: %{"_id" => @gif_id, "server_id" => @server_id, "name" => "dance", "animated" => true}

  defp emojis(docs), do: stub(RepoMock, :get_custom_emojis, fn _ids -> {:ok, docs} end)

  defp send_text(content),
    do: Chat.send_message(%{channel_id: @channel_id, user_id: @user_id, content: content})

  defp react(emoji) do
    Chat.add_reaction(%{
      channel_id: @channel_id,
      message_id: "msg-1",
      user_id: @user_id,
      emoji: emoji
    })
  end

  describe "send_message/1" do
    test "keeps the token in the content" do
      emojis([static_doc()])

      assert {:ok, %Message{content: "hola " <> @static}} = send_text("hola " <> @static)
    end

    test "rejects an animated emoji without Premium and stores nothing" do
      emojis([gif_doc()])
      expect(RepoMock, :insert_message, 0, fn doc -> {:ok, doc} end)

      assert {:error, :custom_emoji_not_allowed} = send_text(@animated)
    end

    test "rejects an emoji of another server without Premium" do
      emojis([static_doc(@other_server)])

      assert {:error, :custom_emoji_not_allowed} = send_text(@static)
    end

    test "a read failure is reported as unavailable" do
      stub(RepoMock, :get_custom_emojis, fn _ids -> {:error, :down} end)

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :custom_emojis_unavailable} = send_text(@static)
      end)
    end

    test "plain text looks no emoji up" do
      expect(RepoMock, :get_custom_emojis, 0, fn _ids -> {:ok, []} end)
      assert {:ok, %Message{}} = send_text("hola")
    end
  end

  describe "send_direct_message/1" do
    setup do
      dm_id = Conversation.id(@user_id, @recipient)

      stub(RepoMock, :get_channel, fn ^dm_id ->
        %{
          "_id" => dm_id,
          "kind" => "dm",
          "name" => "",
          "participants" => [@user_id, @recipient]
        }
      end)

      stub(RepoMock, :get_blocks, fn _ids -> {:ok, []} end)
      stub(RepoMock, :record_last_message, fn _channel, _id, _user, _at -> :ok end)
      :ok
    end

    defp send_dm(content) do
      Chat.send_direct_message(%{sender_id: @user_id, recipient_id: @recipient, content: content})
    end

    test "requires Premium and stores nothing without it" do
      emojis([static_doc()])
      expect(RepoMock, :insert_message, 0, fn doc -> {:ok, doc} end)

      assert {:error, :custom_emoji_not_allowed} = send_dm(@static)
    end

    test "with Premium the emoji goes through" do
      emojis([static_doc()])
      stub(RepoMock, :premium?, fn _user -> true end)

      assert {:ok, _channel, %Message{content: @static}} = send_dm(@static)
    end
  end

  describe "edit_message/1" do
    defp edit(content) do
      Chat.edit_message(%{
        channel_id: @channel_id,
        message_id: "msg-1",
        user_id: @user_id,
        content: content
      })
    end

    setup do
      stub(RepoMock, :update_message, fn "msg-1", @channel_id, @user_id, content, at, _fields ->
        {:ok, Map.merge(message_doc(content), %{"edited_at" => at})}
      end)

      :ok
    end

    test "an emoji the message already had isn't checked again" do
      stub(RepoMock, :get_message, fn "msg-1" -> message_doc(@animated <> " hola") end)
      expect(RepoMock, :get_custom_emojis, 0, fn _ids -> {:ok, []} end)

      assert {:ok, %Message{content: @animated <> " chau"}, :updated} =
               edit(@animated <> " chau")
    end

    test "a new emoji is checked" do
      emojis([gif_doc()])

      assert {:error, :custom_emoji_not_allowed} = edit("hola " <> @animated)
    end
  end

  describe "reactions" do
    test "react with an allowed emoji" do
      emojis([static_doc()])

      expect(RepoMock, :add_reaction, fn %{"emoji" => @static} -> {:ok, :added} end)

      assert {:ok, %{emoji: @static, changed: true}} = react(@static)
    end

    test "react with an animated emoji requires Premium" do
      emojis([gif_doc()])
      expect(RepoMock, :add_reaction, 0, fn _doc -> {:ok, :added} end)

      assert {:error, :custom_emoji_not_allowed} = react(@animated)
    end

    test "a deleted emoji can't be added" do
      emojis([static_doc(@server_id, %{"deleted" => true})])

      assert {:error, :custom_emoji_not_allowed} = react(@static)
    end

    test "removing doesn't check the emoji: it may be deleted or Premium may be gone" do
      expect(RepoMock, :get_custom_emojis, 0, fn _ids -> {:ok, []} end)

      expect(RepoMock, :remove_reaction, fn id ->
        assert String.contains?(id, @animated)
        {:ok, :removed}
      end)

      assert {:ok, %{emoji: @animated, changed: true}} =
               Chat.remove_reaction(%{
                 channel_id: @channel_id,
                 message_id: "msg-1",
                 user_id: @user_id,
                 emoji: @animated
               })
    end

    test "unicode reactions look no emoji up" do
      expect(RepoMock, :get_custom_emojis, 0, fn _ids -> {:ok, []} end)
      expect(RepoMock, :add_reaction, fn _doc -> {:ok, :added} end)

      assert {:ok, %{emoji: "👍"}} = react("👍")
    end

    test "something that isn't an emoji is still invalid" do
      assert {:error, :invalid_emoji} = react("<:party:nope>")
      assert {:error, :invalid_emoji} = react(String.duplicate("a", 100))
    end
  end
end
