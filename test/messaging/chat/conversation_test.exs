defmodule Messaging.Chat.ConversationTest do
  use ExUnit.Case, async: true

  alias Messaging.Chat.{Conversation, Message}

  @a "11111111-1111-4111-8111-111111111111"
  @b "22222222-2222-4222-8222-222222222222"
  @c "33333333-3333-4333-8333-333333333333"

  describe "id/2" do
    test "is the same whoever writes first" do
      assert Conversation.id(@a, @b) == Conversation.id(@b, @a)
    end

    test "is different for every pair" do
      assert Conversation.id(@a, @b) != Conversation.id(@a, @c)
      assert Conversation.id(@a, @b) != Conversation.id(@b, @c)
    end

    test "is a UUID" do
      assert Conversation.id(@a, @b) =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-/
    end
  end

  describe "valid_user_id?/1" do
    test "accepts plain identifiers" do
      assert Conversation.valid_user_id?(@a)
      assert Conversation.valid_user_id?("user_1-b")
    end

    test "rejects anything that could escape a URL path or a Mongo field path" do
      for bad <- [
            "",
            "a.b",
            "a$b",
            "../me",
            "a/b",
            "a b",
            String.duplicate("a", 65),
            nil,
            1,
            %{"$ne" => 1}
          ] do
        refute Conversation.valid_user_id?(bad)
      end
    end
  end

  describe "new_doc/3" do
    test "has no server, kind dm and sorted participants" do
      at = ~U[2026-10-05 10:00:00Z]

      assert %{
               "_id" => id,
               "server_id" => nil,
               "kind" => "dm",
               "participants" => [@a, @b],
               "created_at" => ^at
             } = Conversation.new_doc(@b, @a, at)

      assert id == Conversation.id(@a, @b)
    end
  end

  describe "unread?/2" do
    defp conversation(overrides) do
      struct!(
        Conversation,
        Map.merge(
          %{
            id: "dm-1",
            participants: [@a, @b],
            last_message_at: ~U[2026-10-05 10:00:00Z],
            last_message_user_id: @a,
            last_read_at: %{}
          },
          overrides
        )
      )
    end

    test "is unread for the recipient who never read anything" do
      assert Conversation.unread?(conversation(%{}), @b)
    end

    test "is never unread for the author of the last message" do
      refute Conversation.unread?(conversation(%{}), @a)
    end

    test "is read once the read marker reaches the last message" do
      read = %{@b => ~U[2026-10-05 10:00:00Z]}
      refute Conversation.unread?(conversation(%{last_read_at: read}), @b)
    end

    test "a message after the read marker is unread again" do
      read = %{@b => ~U[2026-10-05 10:00:00Z]}
      later = ~U[2026-10-05 10:05:00Z]
      assert Conversation.unread?(conversation(%{last_read_at: read, last_message_at: later}), @b)
    end

    test "a conversation without messages is never unread" do
      refute Conversation.unread?(conversation(%{last_message_at: nil}), @b)
    end
  end

  describe "to_api/2" do
    test "describes the conversation from the point of view of one participant" do
      message = %Message{
        id: "msg-1",
        channel_id: "dm-1",
        server_id: nil,
        user_id: @a,
        content: "hola",
        inserted_at: ~U[2026-10-05 10:00:00Z]
      }

      api = Conversation.to_api(conversation(%{last_message: message}), @b)

      assert %{
               "id" => "dm-1",
               "partner_id" => @a,
               "unread" => true,
               "last_message_at" => "2026-10-05T10:00:00Z",
               "last_message" => %{"id" => "msg-1", "content" => "hola"}
             } = api

      assert %{"partner_id" => @b, "unread" => false} = Conversation.to_api(conversation(%{}), @a)

      refute Map.has_key?(api, "participants")
    end

    test "a deleted last message is a null last_message" do
      assert %{"last_message" => nil} = Conversation.to_api(conversation(%{}), @b)
    end
  end
end
