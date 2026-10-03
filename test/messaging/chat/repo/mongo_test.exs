mongo_url = System.get_env("MONGO_URL")

if mongo_url do
  defmodule Messaging.Chat.Repo.MongoTest do
    use ExUnit.Case, async: false

    alias Messaging.Chat
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

    test "ensure_indexes/0 creates the history index and can run again" do
      assert :ok = Repo.ensure_indexes()
      assert :ok = Repo.ensure_indexes()

      {:ok, %{"cursor" => %{"firstBatch" => indexes}}} =
        Mongo.command(Messaging.Mongo, listIndexes: "messages")

      assert Enum.any?(indexes, &(&1["name"] == "messages_channel_inserted_at_id"))
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
