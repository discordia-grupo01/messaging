defmodule Messaging.Chat.ReactionsFlowTest do
  use ExUnit.Case, async: true
  import Mox

  alias Messaging.Chat
  alias Messaging.Chat.{Conversation, RepoMock, PermissionsStoreMock}

  setup :verify_on_exit!

  @channel_id "chan-1"
  @server_id "srv-1"
  @user_id "user-1"

  setup do
    stub(RepoMock, :get_clock, fn _key -> nil end)
    stub(RepoMock, :get_channel, fn @channel_id -> text_channel_doc() end)
    stub(RepoMock, :get_message, fn "msg-1" -> message_doc() end)
    stub(RepoMock, :reaction_emojis, fn "msg-1" -> {:ok, []} end)
    stub(RepoMock, :count_reactions, fn "msg-1", _emoji -> {:ok, 1} end)
    stub(RepoMock, :touch_message, fn "msg-1", _at -> :ok end)
    stub(PermissionsStoreMock, :can_add_reactions?, fn _channel, _uid -> {:ok, true} end)
    stub(PermissionsStoreMock, :can_view_channel?, fn _channel, _uid -> {:ok, true} end)
    :ok
  end

  defp text_channel_doc,
    do: %{"_id" => @channel_id, "server_id" => @server_id, "name" => "general", "kind" => "text"}

  defp message_doc(overrides \\ %{}) do
    Map.merge(
      %{
        "_id" => "msg-1",
        "channel_id" => @channel_id,
        "server_id" => @server_id,
        "user_id" => "author",
        "content" => "hola",
        "inserted_at" => ~U[2026-10-10 12:00:00.000Z]
      },
      overrides
    )
  end

  defp params(overrides \\ %{}) do
    Map.merge(
      %{channel_id: @channel_id, message_id: "msg-1", user_id: @user_id, emoji: "👍"},
      overrides
    )
  end

  describe "add_reaction/1" do
    test "CA1: stores the reaction and returns the new count" do
      expect(RepoMock, :add_reaction, fn doc ->
        assert %{
                 "_id" => "msg-1:👍:user-1",
                 "message_id" => "msg-1",
                 "channel_id" => @channel_id,
                 "emoji" => "👍",
                 "user_id" => @user_id,
                 "inserted_at" => %DateTime{}
               } = doc

        {:ok, :added}
      end)

      expect(RepoMock, :count_reactions, fn "msg-1", "👍" -> {:ok, 3} end)
      expect(RepoMock, :touch_message, fn "msg-1", %DateTime{} -> :ok end)

      assert {:ok, %{emoji: "👍", count: 3, changed: true, message: %{id: "msg-1"}}} =
               Chat.add_reaction(params())
    end

    test "reacting twice with the same emoji changes nothing" do
      expect(RepoMock, :add_reaction, fn _doc -> {:ok, :unchanged} end)
      expect(RepoMock, :touch_message, 0, fn _id, _at -> :ok end)

      assert {:ok, %{changed: false, count: 1}} = Chat.add_reaction(params())
    end

    test "CA3: a member without ADD_REACTIONS cannot react" do
      expect(PermissionsStoreMock, :can_add_reactions?, fn %{channel_id: @channel_id}, @user_id ->
        {:ok, false}
      end)

      expect(RepoMock, :add_reaction, 0, fn _doc -> {:ok, :added} end)

      assert {:error, :forbidden} = Chat.add_reaction(params())
    end

    test "a muted member cannot react" do
      expect(RepoMock, :get_clock, fn "member_mute:srv-1:user-1" ->
        %{"state" => "muted", "expires_at" => DateTime.add(DateTime.utc_now(), 60, :second)}
      end)

      assert {:error, :member_muted} = Chat.add_reaction(params())
    end

    test "only a single emoji is accepted" do
      assert {:error, :invalid_emoji} = Chat.add_reaction(params(%{emoji: "hola"}))
      assert {:error, :invalid_emoji} = Chat.add_reaction(params(%{emoji: "👍👍"}))
      assert {:error, :invalid_emoji} = Chat.add_reaction(params(%{emoji: nil}))
    end

    test "the message has to exist in this channel and not be deleted" do
      stub(RepoMock, :get_message, fn
        "other-channel" -> message_doc(%{"channel_id" => "chan-2"})
        "deleted" -> message_doc(%{"deleted_at" => ~U[2026-10-10 13:00:00Z]})
        "missing" -> nil
      end)

      for id <- ["other-channel", "deleted", "missing", 123] do
        assert {:error, :message_not_found} = Chat.add_reaction(params(%{message_id: id}))
      end
    end

    test "a message holds at most 20 different emojis, but those already there can still be used" do
      full = for n <- 1..20, do: "emoji-#{n}"
      stub(RepoMock, :reaction_emojis, fn "msg-1" -> {:ok, ["👍" | tl(full)]} end)

      assert {:error, :too_many_reactions} = Chat.add_reaction(params(%{emoji: "🔥"}))

      expect(RepoMock, :add_reaction, fn _doc -> {:ok, :added} end)
      assert {:ok, %{emoji: "👍"}} = Chat.add_reaction(params(%{emoji: "👍"}))
    end

    test "the channel has to exist" do
      stub(RepoMock, :get_channel, fn _id -> nil end)
      assert {:error, :channel_not_found} = Chat.add_reaction(params())
    end
  end

  describe "remove_reaction/1" do
    test "CA2: removes the member's own reaction and returns the new count" do
      expect(RepoMock, :remove_reaction, fn "msg-1:👍:user-1" -> {:ok, :removed} end)
      expect(RepoMock, :count_reactions, fn "msg-1", "👍" -> {:ok, 0} end)
      expect(RepoMock, :touch_message, fn "msg-1", %DateTime{} -> :ok end)

      assert {:ok, %{emoji: "👍", count: 0, changed: true}} = Chat.remove_reaction(params())
    end

    test "removing a reaction that wasn't there changes nothing" do
      expect(RepoMock, :remove_reaction, fn _id -> {:ok, :unchanged} end)
      expect(RepoMock, :touch_message, 0, fn _id, _at -> :ok end)

      assert {:ok, %{changed: false}} = Chat.remove_reaction(params())
    end

    test "a member who lost ADD_REACTIONS can still take back their own reaction" do
      stub(PermissionsStoreMock, :can_add_reactions?, fn _channel, _uid -> {:ok, false} end)
      expect(RepoMock, :remove_reaction, fn _id -> {:ok, :removed} end)

      assert {:ok, %{changed: true}} = Chat.remove_reaction(params())
    end

    test "but not without seeing the channel" do
      expect(PermissionsStoreMock, :can_view_channel?, fn _channel, @user_id -> {:ok, false} end)
      expect(RepoMock, :remove_reaction, 0, fn _id -> {:ok, :removed} end)

      assert {:error, :forbidden} = Chat.remove_reaction(params())
    end
  end

  describe "direct conversations" do
    @sender "user-1"
    @partner "user-2"

    setup do
      dm = %{
        "_id" => Conversation.id(@sender, @partner),
        "server_id" => nil,
        "name" => "",
        "kind" => "dm",
        "participants" => [@sender, @partner]
      }

      dm_id = dm["_id"]
      stub(RepoMock, :get_channel, fn ^dm_id -> dm end)

      stub(RepoMock, :get_message, fn "msg-1" ->
        message_doc(%{"channel_id" => dm["_id"], "server_id" => nil})
      end)

      {:ok, dm_id: dm["_id"]}
    end

    test "a participant reacts without any server permission", %{dm_id: dm_id} do
      stub(RepoMock, :get_blocks, fn _ids -> {:ok, []} end)
      expect(PermissionsStoreMock, :can_add_reactions?, 0, fn _channel, _uid -> {:ok, true} end)
      expect(RepoMock, :add_reaction, fn %{"channel_id" => ^dm_id} -> {:ok, :added} end)

      assert {:ok, %{changed: true}} = Chat.add_reaction(params(%{channel_id: dm_id}))
    end

    test "nobody reacts in a conversation where one blocked the other", %{dm_id: dm_id} do
      stub(RepoMock, :get_blocks, fn _ids ->
        {:ok, [%{"_id" => "#{@partner}:#{@sender}", "blocker_id" => @partner}]}
      end)

      expect(RepoMock, :add_reaction, 0, fn _doc -> {:ok, :added} end)

      assert {:error, :forbidden} = Chat.add_reaction(params(%{channel_id: dm_id}))
    end

    test "someone outside the conversation doesn't even see it", %{dm_id: dm_id} do
      assert {:error, :channel_not_found} =
               Chat.add_reaction(params(%{channel_id: dm_id, user_id: "intruder"}))
    end
  end

  describe "reactions_for/2" do
    test "summarizes the reactions of a page for whoever is looking" do
      messages = [Messaging.Chat.Message.from_doc(message_doc())]

      expect(RepoMock, :list_reactions, fn ["msg-1"] ->
        {:ok,
         [
           %{
             "message_id" => "msg-1",
             "emoji" => "👍",
             "user_id" => "user-2",
             "inserted_at" => ~U[2026-10-10 12:00:00Z]
           },
           %{
             "message_id" => "msg-1",
             "emoji" => "👍",
             "user_id" => @user_id,
             "inserted_at" => ~U[2026-10-10 12:00:01Z]
           }
         ]}
      end)

      assert {:ok, %{"msg-1" => [%{"emoji" => "👍", "count" => 2, "reacted_by_me" => true}]}} =
               Chat.reactions_for(messages, @user_id)
    end

    test "an empty page doesn't hit the database" do
      expect(RepoMock, :list_reactions, 0, fn _ids -> {:ok, []} end)
      assert {:ok, %{}} = Chat.reactions_for([], @user_id)
    end
  end
end
