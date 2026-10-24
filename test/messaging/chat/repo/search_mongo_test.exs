mongo_url = System.get_env("MONGO_URL")

if mongo_url do
  defmodule Messaging.Chat.Repo.SearchMongoTest do
    use ExUnit.Case, async: false

    alias Messaging.Chat.Repo.Mongo, as: Repo

    @at ~U[2026-10-24 12:00:00.000Z]

    setup do
      id = Messaging.UUID.generate()
      {:ok, server: "srv-" <> id, channel: "chan-" <> id}
    end

    defp channel(id, server_id, kind) do
      :ok =
        Repo.upsert_channel(%{
          "_id" => id,
          "server_id" => server_id,
          "name" => "n",
          "kind" => kind
        })

      id
    end

    describe "list_text_channel_ids/1" do
      test "returns the text channels of that server only", %{server: server} do
        text = for n <- 1..2, do: channel("chan-#{n}-#{server}", server, "text")
        channel("voice-#{server}", server, "voice")
        channel("other-#{server}", "srv-other-#{server}", "text")

        assert {:ok, ids} = Repo.list_text_channel_ids(server)
        assert Enum.sort(ids) == Enum.sort(text)
      end

      test "is empty for a server it never heard of", %{server: server} do
        assert {:ok, []} = Repo.list_text_channel_ids(server)
      end
    end

    describe "list_channel_overrides/1" do
      test "returns the overrides of each channel, keyed by channel id", %{server: server} do
        [hidden, open, plain] = for n <- 1..3, do: "chan-#{n}-#{server}"
        deny_view = [%{role_id: "everyone", allow: [], deny: ["VIEW_CHANNELS"]}]
        allow_view = [%{role_id: "mods", allow: ["VIEW_CHANNELS"], deny: []}]

        {:ok, :applied} = Repo.apply_channel_overrides(server, hidden, deny_view, @at)
        {:ok, :applied} = Repo.apply_channel_overrides(server, open, allow_view, @at)

        assert {:ok, by_channel} = Repo.list_channel_overrides([hidden, open, plain])

        assert by_channel[hidden] == [
                 %{"role_id" => "everyone", "allow" => [], "deny" => ["VIEW_CHANNELS"]}
               ]

        assert by_channel[open] == [
                 %{"role_id" => "mods", "allow" => ["VIEW_CHANNELS"], "deny" => []}
               ]

        refute Map.has_key?(by_channel, plain)
      end

      test "asking for no channels does not touch Mongo" do
        assert {:ok, %{}} = Repo.list_channel_overrides([])
      end
    end

    defp message(channel_id, attrs) do
      doc =
        Map.merge(
          %{
            "_id" => Messaging.UUID.generate_v7(),
            "channel_id" => channel_id,
            "server_id" => "srv-1",
            "user_id" => "ana",
            "content" => "hola",
            "inserted_at" => @at
          },
          attrs
        )

      {:ok, _doc} = Repo.insert_message(doc)
      doc
    end

    defp search(channel_ids, opts) do
      {:ok, docs} = Repo.search_messages(channel_ids, Keyword.put_new(opts, :limit, 50))
      Enum.map(docs, & &1["_id"])
    end

    defp walk(channel_ids, opts, before \\ nil, acc \\ []) do
      {:ok, docs} =
        Repo.search_messages(channel_ids, Keyword.merge(opts, before: before, limit: 3))

      acc = acc ++ Enum.map(docs, & &1["_id"])

      case List.last(docs) do
        nil -> acc
        last -> walk(channel_ids, opts, {last["inserted_at"], last["_id"]}, acc)
      end
    end

    describe "search_messages/2" do
      test "matches part of a word, ignoring case", %{channel: channel} do
        hit = message(channel, %{"content" => "Les mando el Mensaje del DEPLOY"})
        message(channel, %{"content" => "nada que ver"})

        assert search([channel], text: "mens") == [hit["_id"]]
        assert search([channel], text: "deploy") == [hit["_id"]]
        assert search([channel], text: "PLO") == [hit["_id"]]
      end

      test "the term is literal text, never a regex", %{channel: channel} do
        dotted = message(channel, %{"content" => "versión a.b lista"})
        message(channel, %{"content" => "versión axb lista"})
        price = message(channel, %{"content" => "precio (USD) 10"})

        assert search([channel], text: "a.b") == [dotted["_id"]]
        assert search([channel], text: "(usd") == [price["_id"]]
        assert search([channel], text: ".*") == []
      end

      test "filters by author, alone or together with the text", %{channel: channel} do
        ana_deploy = message(channel, %{"user_id" => "ana", "content" => "hice el deploy"})
        ana_other = message(channel, %{"user_id" => "ana", "content" => "buen día"})
        message(channel, %{"user_id" => "beto", "content" => "el deploy falló"})

        assert Enum.sort(search([channel], author_id: "ana")) ==
                 Enum.sort([ana_deploy["_id"], ana_other["_id"]])

        assert search([channel], author_id: "ana", text: "deploy") == [ana_deploy["_id"]]
        assert search([channel], author_id: "nobody") == []
      end

      test "only looks in the given channels", %{channel: channel} do
        mine = message(channel, %{"content" => "deploy"})
        message("other-" <> channel, %{"content" => "deploy"})

        assert search([channel], text: "deploy") == [mine["_id"]]
      end

      test "never returns deleted messages", %{channel: channel} do
        kept = message(channel, %{"content" => "deploy uno"})
        gone = message(channel, %{"content" => "deploy dos"})
        {:ok, _tombstone} = Repo.delete_message(gone["_id"], channel, @at)

        assert search([channel], text: "deploy") == [kept["_id"]]
        assert search([channel], author_id: "ana") == [kept["_id"]]
      end

      test "pages newest first with before, each match once, even with equal timestamps",
           %{channel: channel} do
        docs =
          for i <- 1..8 do
            at = DateTime.add(@at, div(i, 3), :millisecond)
            message(channel, %{"content" => "deploy #{i}", "inserted_at" => at})
          end

        expected =
          docs
          |> Enum.sort_by(&{DateTime.to_unix(&1["inserted_at"], :millisecond), &1["_id"]}, :desc)
          |> Enum.map(& &1["_id"])

        assert walk([channel], text: "deploy") == expected
      end

      test "with no channels there is nothing to search" do
        assert {:ok, []} = Repo.search_messages([], text: "deploy", limit: 10)
      end
    end

    describe "count_search_matches/3" do
      test "counts every live match, with the same filters as the search", %{channel: channel} do
        for i <- 1..4, do: message(channel, %{"content" => "deploy #{i}"})
        message(channel, %{"user_id" => "beto", "content" => "deploy de beto"})
        gone = message(channel, %{"content" => "deploy borrado"})
        {:ok, _tombstone} = Repo.delete_message(gone["_id"], channel, @at)

        assert {:ok, 5} = Repo.count_search_matches([channel], [text: "deploy"], 100)
        assert {:ok, 1} = Repo.count_search_matches([channel], [author_id: "beto"], 100)
        assert {:ok, 0} = Repo.count_search_matches([channel], [text: "nada"], 100)
      end

      test "stops at the limit", %{channel: channel} do
        for i <- 1..5, do: message(channel, %{"content" => "deploy #{i}"})

        assert {:ok, 3} = Repo.count_search_matches([channel], [text: "deploy"], 3)
      end

      test "with no channels the count is zero" do
        assert {:ok, 0} = Repo.count_search_matches([], [text: "deploy"], 100)
      end
    end

    defp index_names(collection) do
      {:ok, %{"cursor" => %{"firstBatch" => indexes}}} =
        Mongo.command(Messaging.Mongo, listIndexes: collection)

      Enum.map(indexes, & &1["name"])
    end

    test "ensure_indexes/0 creates the search indexes and can run again" do
      assert :ok = Repo.ensure_indexes()
      assert :ok = Repo.ensure_indexes()

      assert "messages_channel_user_inserted_at_id" in index_names("messages")
      assert "channels_server_kind" in index_names("channels")
    end
  end
else
  defmodule Messaging.Chat.Repo.SearchMongoTest do
    use ExUnit.Case

    test "skipped: set MONGO_URL to run this against a real Mongo instance" do
      IO.puts("\nSkipping Chat.Repo.Mongo search test: MONGO_URL not set.\n")
    end
  end
end
