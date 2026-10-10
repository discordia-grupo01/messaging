defmodule Messaging.Chat.ReactionTest do
  use ExUnit.Case, async: true

  alias Messaging.Chat.Reaction

  describe "validate_emoji/1" do
    test "accepts any single emoji, including multi code point ones" do
      for emoji <- ["👍", "❤️", "😂", "🎉", "🔥", "👨‍👩‍👧", "👍🏽", "🇦🇷", "1️⃣", "#️⃣", "©️", "⭐"] do
        assert {:ok, ^emoji} = Reaction.validate_emoji(emoji), "rejected #{emoji}"
      end
    end

    test "rejects text, several emojis, empty and non strings" do
      for bad <- ["a", "ab", "1", ":)", " ", "", "👍👍", "👍 ", "hola👍", nil, 42, %{}] do
        assert {:error, :invalid_emoji} = Reaction.validate_emoji(bad), "accepted #{inspect(bad)}"
      end
    end

    test "rejects invalid UTF-8 and oversized input" do
      assert {:error, :invalid_emoji} = Reaction.validate_emoji(<<0xFF, 0xFE>>)
      assert {:error, :invalid_emoji} = Reaction.validate_emoji("👍" <> String.duplicate("‍👍", 20))
    end
  end

  describe "summarize/2" do
    defp doc(message_id, emoji, user_id, second) do
      %{
        "message_id" => message_id,
        "emoji" => emoji,
        "user_id" => user_id,
        "inserted_at" => DateTime.add(~U[2026-10-10 12:00:00Z], second, :second)
      }
    end

    test "counts each emoji once per message, in the order it was first used" do
      docs = [
        doc("m1", "🔥", "u2", 3),
        doc("m1", "👍", "u1", 1),
        doc("m1", "🔥", "u1", 2),
        doc("m1", "👍", "u3", 4),
        doc("m2", "😂", "u2", 1)
      ]

      assert %{
               "m1" => [
                 %{"emoji" => "👍", "count" => 2, "reacted_by_me" => true},
                 %{"emoji" => "🔥", "count" => 2, "reacted_by_me" => true}
               ],
               "m2" => [%{"emoji" => "😂", "count" => 1, "reacted_by_me" => false}]
             } = Reaction.summarize(docs, "u1")
    end

    test "reacted_by_me depends on who is looking" do
      docs = [doc("m1", "👍", "u1", 1)]

      assert %{"m1" => [%{"reacted_by_me" => true}]} = Reaction.summarize(docs, "u1")
      assert %{"m1" => [%{"reacted_by_me" => false}]} = Reaction.summarize(docs, "u2")
    end

    test "no reactions, no entries" do
      assert Reaction.summarize([], "u1") == %{}
    end
  end
end
