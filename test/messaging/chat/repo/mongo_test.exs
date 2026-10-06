mongo_url = System.get_env("MONGO_URL")

if mongo_url do
  defmodule Messaging.Chat.Repo.MongoTest do
    use ExUnit.Case, async: false

    alias Messaging.Chat
    alias Messaging.Chat.Conversation
    alias Messaging.Chat.Repo.Mongo, as: Repo

    setup do
      previous = Application.get_env(:messaging, :chat_repo)
      Application.put_env(:messaging, :chat_repo, Repo)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:messaging, :chat_repo, previous),
          else: Application.delete_env(:messaging, :chat_repo)
      end)

      {:ok, channel_id: "chan-" <> Messaging.UUID.generate()}
    end

    defp seed(channel_id, count) do
      base = ~U[2026-09-28 12:00:00.000Z]

      docs =
        for i <- 1..count do
          %{
            "_id" => Messaging.UUID.generate(),
            "channel_id" => channel_id,
            "server_id" => "srv-1",
            "user_id" => "user-1",
            "content" => "mensaje #{i}",
            "inserted_at" => DateTime.add(base, div(i, 3), :millisecond)
          }
        end

      for doc <- Enum.shuffle(docs), do: {:ok, _} = Repo.insert_message(doc)

      docs
      |> Enum.sort_by(&{DateTime.to_unix(&1["inserted_at"], :millisecond), &1["_id"]})
      |> Enum.map(& &1["_id"])
    end

    defp walk_back(channel_id, before, acc) do
      {:ok, page, cursor} = Chat.list_messages(channel_id, limit: 7, before: before)
      acc = Enum.map(page, & &1.id) ++ acc
      if cursor, do: walk_back(channel_id, cursor, acc), else: acc
    end

    defp walk_forward(channel_id, last_id, acc) do
      {:ok, page, cursor} = Chat.list_messages(channel_id, limit: 7, after: last_id)
      acc = acc ++ Enum.map(page, & &1.id)
      if cursor, do: walk_forward(channel_id, cursor, acc), else: acc
    end

    test "paging backwards visits every message once, in chronological order, even with equal timestamps",
         %{channel_id: channel_id} do
      expected = seed(channel_id, 40)

      assert walk_back(channel_id, nil, []) == expected
    end

    test "paging forwards from a cursor returns everything after it, once and in order",
         %{channel_id: channel_id} do
      [first | rest] = seed(channel_id, 40)

      assert walk_forward(channel_id, first, []) == rest
    end

    test "the latest page holds the newest messages, oldest first", %{channel_id: channel_id} do
      expected = seed(channel_id, 12)

      {:ok, page, cursor} = Chat.list_messages(channel_id, limit: 5)

      assert Enum.map(page, & &1.id) == Enum.take(expected, -5)
      assert cursor == hd(Enum.take(expected, -5))
    end

    test "messages of other channels are never returned", %{channel_id: channel_id} do
      seed("other-" <> channel_id, 5)
      expected = seed(channel_id, 5)

      {:ok, page, nil} = Chat.list_messages(channel_id)

      assert Enum.map(page, & &1.id) == expected
    end

    test "a cursor from another channel is rejected", %{channel_id: channel_id} do
      [foreign | _] = seed("other-" <> channel_id, 3)

      assert {:error, :invalid_cursor} = Chat.list_messages(channel_id, before: foreign)
    end

    defp cache_channel(server_id, channel_id) do
      :ok =
        Repo.upsert_channel(%{
          "_id" => channel_id,
          "server_id" => server_id,
          "name" => "general",
          "kind" => "text"
        })
    end

    defp message_count(channel_id) do
      {:ok, n} = Mongo.count_documents(Messaging.Mongo, "messages", %{"channel_id" => channel_id})
      n
    end

    test "delete_server_data/2 removes the messages and cached channels of that server only",
         %{channel_id: channel_a} do
      server = "srv-" <> Messaging.UUID.generate()
      channel_b = "chan-" <> Messaging.UUID.generate()
      other_server = "srv-" <> Messaging.UUID.generate()
      other_channel = "chan-" <> Messaging.UUID.generate()

      for {srv, ch} <- [{server, channel_a}, {server, channel_b}, {other_server, other_channel}] do
        cache_channel(srv, ch)
        seed(ch, 5)
      end

      assert :ok = Repo.delete_server_data(server, [channel_a, channel_b])

      assert message_count(channel_a) == 0
      assert message_count(channel_b) == 0
      assert Repo.get_channel(channel_a) == nil
      assert Repo.get_channel(channel_b) == nil
      assert message_count(other_channel) == 5
      assert %{"server_id" => ^other_server} = Repo.get_channel(other_channel)
    end

    test "delete_server_data/2 also purges channels it only knows from its own cache",
         %{channel_id: channel_id} do
      server = "srv-" <> Messaging.UUID.generate()
      cache_channel(server, channel_id)
      seed(channel_id, 3)

      assert :ok = Repo.delete_server_data(server, [])

      assert message_count(channel_id) == 0
      assert Repo.get_channel(channel_id) == nil
    end

    test "delete_server_data/2 purges channel ids from the event even if the cache never had them",
         %{channel_id: channel_id} do
      seed(channel_id, 3)

      assert :ok = Repo.delete_server_data("srv-" <> Messaging.UUID.generate(), [channel_id])

      assert message_count(channel_id) == 0
    end

    test "delete_server_data/2 is idempotent and fine for a server it never heard of" do
      server = "srv-" <> Messaging.UUID.generate()

      assert :ok = Repo.delete_server_data(server, [])
      assert :ok = Repo.delete_server_data(server, ["chan-" <> Messaging.UUID.generate()])
    end

    test "delete_channel/1 removes the channel and its messages, leaving other channels intact",
         %{channel_id: channel_id} do
      other_id = "other-" <> channel_id
      kept = seed(other_id, 3)
      seed(channel_id, 5)

      :ok =
        Repo.upsert_channel(%{
          "_id" => channel_id,
          "server_id" => "srv-1",
          "name" => "general",
          "kind" => "text"
        })

      assert :ok = Repo.delete_channel(channel_id)

      assert Repo.get_channel(channel_id) == nil
      assert {:ok, []} = Repo.list_messages(channel_id, limit: 50)
      assert {:ok, page} = Repo.list_messages(other_id, limit: 50)
      assert Enum.sort(Enum.map(page, & &1["_id"])) == Enum.sort(kept)
    end

    test "delete_channel/1 is idempotent", %{channel_id: channel_id} do
      assert :ok = Repo.delete_channel(channel_id)
      assert :ok = Repo.delete_channel(channel_id)
    end

    defp one_message(channel_id, user_id) do
      doc = %{
        "_id" => Messaging.UUID.generate_v7(),
        "channel_id" => channel_id,
        "server_id" => "srv-1",
        "user_id" => user_id,
        "content" => "original",
        "inserted_at" => ~U[2026-09-28 12:00:00.000Z]
      }

      {:ok, _} = Repo.insert_message(doc)
      doc
    end

    test "update_message/5 changes only the content and edited_at, and returns the new document",
         %{channel_id: channel_id} do
      doc = one_message(channel_id, "user-a")
      edited_at = ~U[2026-09-28 13:00:00.250Z]

      assert {:ok, updated} =
               Repo.update_message(doc["_id"], channel_id, "user-a", "corregido", edited_at)

      assert updated["content"] == "corregido"
      assert updated["edited_at"] == edited_at
      assert updated["inserted_at"] == doc["inserted_at"]
      assert updated["user_id"] == "user-a"
      assert Repo.get_message(doc["_id"])["content"] == "corregido"
    end

    test "update_message/5 is a no-op (nil) when the author or the channel do not match",
         %{channel_id: channel_id} do
      doc = one_message(channel_id, "user-a")
      at = ~U[2026-09-28 13:00:00.000Z]

      assert {:ok, nil} = Repo.update_message(doc["_id"], channel_id, "intruder", "robado", at)
      assert {:ok, nil} = Repo.update_message(doc["_id"], "other-channel", "user-a", "robado", at)
      assert {:ok, nil} = Repo.update_message("does-not-exist", channel_id, "user-a", "x", at)

      assert %{"content" => "original"} = Repo.get_message(doc["_id"])
      refute Map.has_key?(Repo.get_message(doc["_id"]), "edited_at")
    end

    test "history returns the edit and keeps the original position", %{channel_id: channel_id} do
      first = one_message(channel_id, "user-a")
      Process.sleep(5)
      second = one_message(channel_id, "user-b")

      {:ok, _} =
        Repo.update_message(
          first["_id"],
          channel_id,
          "user-a",
          "corregido",
          ~U[2026-09-28 14:00:00.000Z]
        )

      {:ok, page, nil} = Chat.list_messages(channel_id)

      assert [
               %{id: id1, content: "corregido", edited_at: %DateTime{}},
               %{id: id2, edited_at: nil}
             ] =
               page

      assert id1 == first["_id"] and id2 == second["_id"]
    end

    test "update_message/5 also stamps changed_at, the cursor of the change feed",
         %{channel_id: channel_id} do
      doc = one_message(channel_id, "user-a")
      edited_at = ~U[2026-09-28 13:00:00.250Z]

      {:ok, updated} = Repo.update_message(doc["_id"], channel_id, "user-a", "x", edited_at)

      assert updated["changed_at"] == edited_at
    end

    test "ensure_indexes/0 creates the history index and can run again" do
      assert :ok = Repo.ensure_indexes()
      assert :ok = Repo.ensure_indexes()

      {:ok, %{"cursor" => %{"firstBatch" => indexes}}} =
        Mongo.command(Messaging.Mongo, listIndexes: "messages")

      assert Enum.any?(indexes, &(&1["name"] == "messages_channel_inserted_at_id"))

      {:ok, %{"cursor" => %{"firstBatch" => channel_indexes}}} =
        Mongo.command(Messaging.Mongo, listIndexes: "channels")

      assert Enum.any?(channel_indexes, &(&1["name"] == "dm_participants_last_message_at"))
    end

    defp edit(doc, channel_id, at) do
      {:ok, _} = Repo.update_message(doc["_id"], channel_id, doc["user_id"], "editado", at)
    end

    test "list_changes/3 returns edited messages since the cursor oldest first, whatever their age",
         %{channel_id: channel_id} do
      ancient = %{
        one_message(channel_id, "user-a")
        | "inserted_at" => ~U[2020-01-01 00:00:00.000Z]
      }

      {:ok, _} = Repo.insert_message(Map.put(ancient, "_id", "ancient-" <> channel_id))
      ancient = Map.put(ancient, "_id", "ancient-" <> channel_id)
      recent = one_message(channel_id, "user-b")
      untouched = one_message(channel_id, "user-c")

      edit(recent, channel_id, ~U[2026-09-28 13:00:02.000Z])
      edit(ancient, channel_id, ~U[2026-09-28 13:00:05.000Z])

      assert {:ok, docs} = Repo.list_changes(channel_id, ~U[2026-09-28 13:00:00.000Z], 10)

      assert Enum.map(docs, & &1["_id"]) == [recent["_id"], ancient["_id"]]
      refute untouched["_id"] in Enum.map(docs, & &1["_id"])
    end

    test "list_changes/3 includes the exact cursor instant and excludes earlier changes",
         %{channel_id: channel_id} do
      before_cursor = one_message(channel_id, "user-a")
      at_cursor = one_message(channel_id, "user-b")

      edit(before_cursor, channel_id, ~U[2026-09-28 13:00:00.999Z])
      edit(at_cursor, channel_id, ~U[2026-09-28 13:00:01.000Z])

      {:ok, docs} = Repo.list_changes(channel_id, ~U[2026-09-28 13:00:01.000Z], 10)

      assert Enum.map(docs, & &1["_id"]) == [at_cursor["_id"]]
    end

    test "list_changes/3 never leaks changes of other channels and honors the limit",
         %{channel_id: channel_id} do
      other = one_message("other-" <> channel_id, "user-x")
      edit(other, "other-" <> channel_id, ~U[2026-09-28 13:00:01.000Z])

      for i <- 1..5 do
        doc = one_message(channel_id, "user-a")
        edit(doc, channel_id, DateTime.add(~U[2026-09-28 13:00:02.000Z], i, :second))
      end

      {:ok, docs} = Repo.list_changes(channel_id, ~U[2026-09-28 13:00:00.000Z], 3)

      assert length(docs) == 3
      assert Enum.all?(docs, &(&1["channel_id"] == channel_id))
    end

    test "list_changes/3 is empty when nothing was ever edited", %{channel_id: channel_id} do
      one_message(channel_id, "user-a")

      assert {:ok, []} = Repo.list_changes(channel_id, ~U[2000-01-01 00:00:00.000Z], 10)
    end

    test "delete_message/3 erases the content, stamps deleted_at and changed_at, and keeps the tombstone",
         %{channel_id: channel_id} do
      doc = one_message(channel_id, "user-a")
      at = ~U[2026-09-28 13:00:00.500Z]

      assert {:ok, tombstone} = Repo.delete_message(doc["_id"], channel_id, at)

      assert tombstone["content"] == ""
      assert tombstone["deleted_at"] == at
      assert tombstone["changed_at"] == at
      assert tombstone["inserted_at"] == doc["inserted_at"]
      assert tombstone["user_id"] == "user-a"
      assert %{"deleted_at" => ^at, "content" => ""} = Repo.get_message(doc["_id"])
    end

    test "delete_message/3 is a no-op (nil) for another channel, a missing id or an already deleted message",
         %{channel_id: channel_id} do
      doc = one_message(channel_id, "user-a")
      at = ~U[2026-09-28 13:00:00.000Z]

      assert {:ok, nil} = Repo.delete_message(doc["_id"], "other-channel", at)
      assert {:ok, nil} = Repo.delete_message("does-not-exist", channel_id, at)
      assert %{"content" => "original"} = Repo.get_message(doc["_id"])

      assert {:ok, %{}} = Repo.delete_message(doc["_id"], channel_id, at)
      later = ~U[2026-09-28 14:00:00.000Z]
      assert {:ok, nil} = Repo.delete_message(doc["_id"], channel_id, later)
      assert %{"deleted_at" => ^at} = Repo.get_message(doc["_id"])
    end

    test "a deleted message disappears from the history in both directions",
         %{channel_id: channel_id} do
      [first, second, third] = for _ <- 1..3, do: one_message(channel_id, "user-a")
      {:ok, _} = Repo.delete_message(second["_id"], channel_id, ~U[2026-09-28 13:00:00.000Z])

      {:ok, latest, nil} = Chat.list_messages(channel_id)
      assert Enum.map(latest, & &1.id) == [first["_id"], third["_id"]]

      {:ok, forward, nil} = Chat.list_messages(channel_id, after: first["_id"])
      assert Enum.map(forward, & &1.id) == [third["_id"]]

      {:ok, backward, nil} = Chat.list_messages(channel_id, before: third["_id"])
      assert Enum.map(backward, & &1.id) == [first["_id"]]
    end

    test "a deleted message still works as a cursor, so a client whose last message was deleted can catch up",
         %{channel_id: channel_id} do
      [first, second, third] = for _ <- 1..3, do: one_message(channel_id, "user-a")
      {:ok, _} = Repo.delete_message(second["_id"], channel_id, ~U[2026-09-28 13:00:00.000Z])

      assert {:ok, forward, nil} = Chat.list_messages(channel_id, after: second["_id"])
      assert Enum.map(forward, & &1.id) == [third["_id"]]
      assert first["_id"] != second["_id"]
    end

    test "update_message/5 cannot resurrect or edit a deleted message", %{channel_id: channel_id} do
      doc = one_message(channel_id, "user-a")
      {:ok, _} = Repo.delete_message(doc["_id"], channel_id, ~U[2026-09-28 13:00:00.000Z])

      assert {:ok, nil} =
               Repo.update_message(
                 doc["_id"],
                 channel_id,
                 "user-a",
                 "revivido",
                 ~U[2026-09-28 14:00:00.000Z]
               )

      assert %{"content" => ""} = Repo.get_message(doc["_id"])
    end

    test "list_changes/3 returns deletions together with edits, and Chat splits them",
         %{channel_id: channel_id} do
      edited = one_message(channel_id, "user-a")
      deleted = one_message(channel_id, "user-b")
      untouched = one_message(channel_id, "user-c")

      edit(edited, channel_id, ~U[2026-09-28 13:00:02.000Z])
      {:ok, _} = Repo.delete_message(deleted["_id"], channel_id, ~U[2026-09-28 13:00:03.000Z])

      assert {:ok, [changed], [deleted_id]} =
               Chat.list_changes(channel_id, ~U[2026-09-28 13:00:05.000Z])

      assert changed.id == edited["_id"]
      assert deleted_id == deleted["_id"]
      refute untouched["_id"] in [changed.id, deleted_id]
    end

    test "a message edited and then deleted shows up only as deleted", %{channel_id: channel_id} do
      doc = one_message(channel_id, "user-a")
      edit(doc, channel_id, ~U[2026-09-28 13:00:02.000Z])
      {:ok, _} = Repo.delete_message(doc["_id"], channel_id, ~U[2026-09-28 13:00:03.000Z])

      assert {:ok, [], [deleted_id]} =
               Chat.list_changes(channel_id, ~U[2026-09-28 13:00:05.000Z])

      assert deleted_id == doc["_id"]
    end

    defp dm_doc(user_a, user_b) do
      Conversation.new_doc(user_a, user_b, ~U[2026-10-05 09:00:00.000Z])
    end

    defp dm_users do
      suffix = Messaging.UUID.generate()
      {"a-" <> suffix, "b-" <> suffix}
    end

    test "ensure_conversation/1 is idempotent and never overwrites what the conversation already has" do
      {a, b} = dm_users()
      doc = dm_doc(a, b)

      assert :ok = Repo.ensure_conversation(doc)
      assert :ok = Repo.record_last_message(doc["_id"], "m-1", a, ~U[2026-10-05 10:00:00.000Z])
      assert :ok = Repo.ensure_conversation(doc)

      stored = Repo.get_channel(doc["_id"])
      assert stored["kind"] == "dm"
      assert stored["participants"] == Enum.sort([a, b])
      assert stored["last_message_id"] == "m-1"
    end

    test "many first messages at once create exactly one conversation" do
      {a, b} = dm_users()
      doc = dm_doc(a, b)

      1..20
      |> Task.async_stream(fn _ -> Repo.ensure_conversation(doc) end, max_concurrency: 20)
      |> Enum.each(fn {:ok, result} -> assert result == :ok end)

      {:ok, found} = Repo.list_conversations(a, 10)
      assert found == []

      :ok = Repo.record_last_message(doc["_id"], "m-1", a, ~U[2026-10-05 10:00:00.000Z])
      assert {:ok, [%{"_id" => id}]} = Repo.list_conversations(a, 10)
      assert id == doc["_id"]
    end

    test "record_last_message/4 keeps the newest, whatever order the writes finish in" do
      {a, b} = dm_users()
      doc = dm_doc(a, b)
      :ok = Repo.ensure_conversation(doc)

      :ok = Repo.record_last_message(doc["_id"], "m-2", b, ~U[2026-10-05 10:00:02.000Z])
      :ok = Repo.record_last_message(doc["_id"], "m-1", a, ~U[2026-10-05 10:00:01.000Z])

      stored = Repo.get_channel(doc["_id"])
      assert stored["last_message_id"] == "m-2"
      assert stored["last_message_user_id"] == b
      assert stored["last_message_at"] == ~U[2026-10-05 10:00:02.000Z]
    end

    test "record_last_message/4 does nothing for something that is not a direct conversation",
         %{channel_id: channel_id} do
      :ok =
        Repo.upsert_channel(%{
          "_id" => channel_id,
          "server_id" => "s",
          "name" => "n",
          "kind" => "text"
        })

      assert :ok = Repo.record_last_message(channel_id, "m-1", "u", ~U[2026-10-05 10:00:00.000Z])
      refute Map.has_key?(Repo.get_channel(channel_id), "last_message_id")
    end

    test "list_conversations/2 returns only my conversations with messages, newest first" do
      {a, b} = dm_users()
      c = "c-" <> Messaging.UUID.generate()
      with_b = dm_doc(a, b)
      with_c = dm_doc(a, c)
      empty = dm_doc(a, "d-" <> Messaging.UUID.generate())
      other_people = dm_doc(b, c)

      for doc <- [with_b, with_c, empty, other_people], do: :ok = Repo.ensure_conversation(doc)
      :ok = Repo.record_last_message(with_b["_id"], "m-b", b, ~U[2026-10-05 10:00:00.000Z])
      :ok = Repo.record_last_message(with_c["_id"], "m-c", c, ~U[2026-10-05 11:00:00.000Z])
      :ok = Repo.record_last_message(other_people["_id"], "m-x", c, ~U[2026-10-05 12:00:00.000Z])

      assert {:ok, docs} = Repo.list_conversations(a, 10)
      assert Enum.map(docs, & &1["_id"]) == [with_c["_id"], with_b["_id"]]

      assert {:ok, [only]} = Repo.list_conversations(a, 1)
      assert only["_id"] == with_c["_id"]
    end

    test "list_conversations/2 never mixes in server channels" do
      {a, _b} = dm_users()

      assert {:ok, []} = Repo.list_conversations(a, 10)
    end

    test "mark_read/3 only moves forward, never back" do
      {a, b} = dm_users()
      doc = dm_doc(a, b)
      :ok = Repo.ensure_conversation(doc)

      :ok = Repo.mark_read(doc["_id"], b, ~U[2026-10-05 10:00:05.000Z])
      :ok = Repo.mark_read(doc["_id"], b, ~U[2026-10-05 10:00:01.000Z])

      assert %{"last_read_at" => %{^b => read}} = Repo.get_channel(doc["_id"])
      assert read == ~U[2026-10-05 10:00:05.000Z]
    end

    test "mark_read/3 does nothing for someone who is not a participant" do
      {a, b} = dm_users()
      doc = dm_doc(a, b)
      :ok = Repo.ensure_conversation(doc)

      assert :ok = Repo.mark_read(doc["_id"], "intruder", ~U[2026-10-05 10:00:00.000Z])
      refute Map.has_key?(Repo.get_channel(doc["_id"]), "last_read_at")
    end

    test "get_messages/1 returns live messages by id and skips deleted ones",
         %{channel_id: channel_id} do
      kept = one_message(channel_id, "user-a")
      gone = one_message(channel_id, "user-a")
      {:ok, _} = Repo.delete_message(gone["_id"], channel_id, ~U[2026-10-05 10:00:00.000Z])

      assert {:ok, [found]} = Repo.get_messages([kept["_id"], gone["_id"], "ghost"])
      assert found["_id"] == kept["_id"]
    end

    test "the whole flow: first message, unread for the recipient, read, unread again" do
      {a, b} = dm_users()
      Mox.stub(Messaging.Chat.UsersClientMock, :user_exists?, fn _id, _jwt -> {:ok, true} end)

      assert {:ok, channel, first} =
               Chat.send_direct_message(%{
                 sender_id: a,
                 recipient_id: b,
                 content: "hola",
                 raw_jwt: "jwt"
               })

      assert {:ok, [%{unread: unread_for_b}]} = list_for(b)
      assert unread_for_b
      assert {:ok, [%{unread: false}]} = list_for(a)

      assert :ok = Chat.mark_read(channel.channel_id, b)
      assert {:ok, [%{unread: false}]} = list_for(b)

      Process.sleep(5)

      assert {:ok, _channel, _second} =
               Chat.send_direct_message(%{
                 sender_id: a,
                 recipient_id: b,
                 content: "otra",
                 raw_jwt: "jwt"
               })

      assert {:ok, [%{unread: true, last_message: %{content: "otra"}}]} = list_for(b)
      assert first.id != nil
      assert {:ok, history, nil} = Chat.list_messages(channel.channel_id)
      assert Enum.map(history, & &1.content) == ["hola", "otra"]
    end

    defp list_for(user_id) do
      with {:ok, conversations} <- Chat.list_conversations(user_id) do
        {:ok,
         Enum.map(conversations, fn c ->
           %{
             unread: Conversation.unread?(c, user_id),
             last_message: c.last_message
           }
         end)}
      end
    end

    test "ensure_indexes/0 creates a partial index so unedited messages are not indexed" do
      assert :ok = Repo.ensure_indexes()

      {:ok, %{"cursor" => %{"firstBatch" => indexes}}} =
        Mongo.command(Messaging.Mongo, listIndexes: "messages")

      assert %{"partialFilterExpression" => %{"changed_at" => %{"$exists" => true}}} =
               Enum.find(indexes, &(&1["name"] == "messages_channel_changed_at"))
    end
  end
else
  defmodule Messaging.Chat.Repo.MongoTest do
    use ExUnit.Case

    test "skipped: set MONGO_URL to run this against a real Mongo instance" do
      IO.puts("\nSkipping Chat.Repo.Mongo test: MONGO_URL not set.\n")
    end
  end
end
