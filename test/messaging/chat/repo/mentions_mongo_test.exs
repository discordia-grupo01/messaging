mongo_url = System.get_env("MONGO_URL")

if mongo_url do
  defmodule Messaging.Chat.Repo.MentionsMongoTest do
    use ExUnit.Case, async: false

    alias Messaging.Chat.{Message, UserMention}
    alias Messaging.Chat.Repo.Mongo, as: Repo

    defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

    defp message(overrides \\ %{}) do
      struct!(
        %Message{
          id: Messaging.UUID.generate(),
          channel_id: unique("chan"),
          server_id: unique("srv"),
          user_id: "author-1",
          content: "<@x>",
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:millisecond)
        },
        overrides
      )
    end

    defp count(filter), do: Mongo.count_documents!(Messaging.Mongo, "mentions", filter)

    describe "insert_mentions/1" do
      test "stores one notification per user and reports who is new" do
        msg = message()
        docs = Enum.map(["ana", "bob"], &UserMention.new_doc(msg, &1))

        assert {:ok, ["ana", "bob"]} = Repo.insert_mentions(docs)
        assert count(%{"message_id" => msg.id}) == 2
      end

      test "is idempotent: recording the same mention again adds nothing and reports nobody new" do
        msg = message()
        assert {:ok, ["ana"]} = Repo.insert_mentions([UserMention.new_doc(msg, "ana")])

        docs = Enum.map(["ana", "bob"], &UserMention.new_doc(msg, &1))
        assert {:ok, ["bob"]} = Repo.insert_mentions(docs)
        assert count(%{"message_id" => msg.id}) == 2
      end

      test "nothing to insert is fine" do
        assert {:ok, []} = Repo.insert_mentions([])
      end
    end

    test "delete_mentions/2 keeps only the users still mentioned" do
      msg = message()
      docs = Enum.map(["ana", "bob", "caro"], &UserMention.new_doc(msg, &1))
      {:ok, _} = Repo.insert_mentions(docs)

      assert :ok = Repo.delete_mentions(msg.id, ["bob"])
      assert count(%{"message_id" => msg.id}) == 1
      assert count(%{"message_id" => msg.id, "user_id" => "bob"}) == 1

      assert :ok = Repo.delete_mentions(msg.id, [])
      assert count(%{"message_id" => msg.id}) == 0
    end

    describe "unread mentions" do
      test "lists a user's unread mentions newest first, and reading a channel clears only that channel" do
        user = unique("user")
        channel = unique("chan")
        other_channel = unique("chan")
        base = ~U[2026-10-06 12:00:00.000Z]

        older = message(%{channel_id: channel, inserted_at: base})
        newer = message(%{channel_id: channel, inserted_at: DateTime.add(base, 60, :second)})

        elsewhere =
          message(%{channel_id: other_channel, inserted_at: DateTime.add(base, 30, :second)})

        for msg <- [older, newer, elsewhere],
            do: {:ok, _} = Repo.insert_mentions([UserMention.new_doc(msg, user)])

        # someone else's mention never shows up
        {:ok, _} = Repo.insert_mentions([UserMention.new_doc(newer, unique("other"))])

        assert {:ok, docs} = Repo.list_unread_mentions(user, 10)
        assert Enum.map(docs, & &1["message_id"]) == [newer.id, elsewhere.id, older.id]

        assert {:ok, [first]} = Repo.list_unread_mentions(user, 1)
        assert first["message_id"] == newer.id

        assert :ok = Repo.mark_mentions_read(user, channel, DateTime.utc_now())
        assert {:ok, [left]} = Repo.list_unread_mentions(user, 10)
        assert left["message_id"] == elsewhere.id
      end
    end

    test "delete_member_mentions/2 only touches that member in that server" do
      server = unique("srv")
      msg = message(%{server_id: server})
      elsewhere = message()

      {:ok, _} =
        Repo.insert_mentions([UserMention.new_doc(msg, "ana"), UserMention.new_doc(msg, "bob")])

      {:ok, _} = Repo.insert_mentions([UserMention.new_doc(elsewhere, "ana")])

      assert :ok = Repo.delete_member_mentions(server, "ana")

      assert count(%{"server_id" => server, "user_id" => "ana"}) == 0
      assert count(%{"server_id" => server, "user_id" => "bob"}) == 1
      assert count(%{"message_id" => elsewhere.id, "user_id" => "ana"}) == 1
    end

    describe "messages with mentions" do
      test "the mention fields are stored and read back, and an edit replaces them" do
        msg = message()

        doc = %{
          "_id" => msg.id,
          "channel_id" => msg.channel_id,
          "server_id" => msg.server_id,
          "user_id" => msg.user_id,
          "content" => "<@ana>",
          "inserted_at" => msg.inserted_at,
          "mentions" => ["ana"],
          "mention_roles" => [],
          "mention_everyone" => false
        }

        {:ok, _} = Repo.insert_message(doc)
        assert %Message{mentions: ["ana"]} = msg.id |> Repo.get_message() |> Message.from_doc()

        fields = %{"mentions" => [], "mention_roles" => ["r1"], "mention_everyone" => true}

        assert {:ok, updated} =
                 Repo.update_message(
                   msg.id,
                   msg.channel_id,
                   msg.user_id,
                   "@everyone",
                   DateTime.utc_now(),
                   fields
                 )

        assert %Message{
                 content: "@everyone",
                 mentions: [],
                 mention_roles: ["r1"],
                 mention_everyone: true
               } = Message.from_doc(updated)
      end

      test "an old message without the fields reads as mentioning nobody" do
        msg = message()

        {:ok, _} =
          Repo.insert_message(%{
            "_id" => msg.id,
            "channel_id" => msg.channel_id,
            "server_id" => msg.server_id,
            "user_id" => msg.user_id,
            "content" => "viejo",
            "inserted_at" => msg.inserted_at
          })

        assert %Message{mentions: [], mention_roles: [], mention_everyone: false} =
                 msg.id |> Repo.get_message() |> Message.from_doc()
      end
    end

    describe "cleanup with the channel or the server" do
      test "deleting a channel deletes its mentions" do
        msg = message()
        {:ok, _} = Repo.insert_mentions([UserMention.new_doc(msg, "ana")])

        assert :ok = Repo.delete_channel(msg.channel_id)
        assert count(%{"channel_id" => msg.channel_id}) == 0
      end

      test "deleting a server deletes the mentions of all its channels" do
        server = unique("srv")
        a = message(%{server_id: server})
        b = message(%{server_id: server})
        for msg <- [a, b], do: {:ok, _} = Repo.insert_mentions([UserMention.new_doc(msg, "ana")])

        assert :ok = Repo.delete_server_data(server, [a.channel_id, b.channel_id])
        assert count(%{"server_id" => server}) == 0
      end
    end
  end
end
