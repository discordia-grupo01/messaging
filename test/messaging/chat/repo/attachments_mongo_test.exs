mongo_url = System.get_env("MONGO_URL")

if mongo_url do
  defmodule Messaging.Chat.Repo.AttachmentsMongoTest do
    use ExUnit.Case, async: false

    alias Messaging.Chat.Repo.Mongo, as: Repo

    setup do
      previous = Application.get_env(:messaging, :chat_repo)
      Application.put_env(:messaging, :chat_repo, Repo)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:messaging, :chat_repo, previous),
          else: Application.delete_env(:messaging, :chat_repo)
      end)

      id = Messaging.UUID.generate()
      {:ok, user: "user-" <> id, channel: "chan-" <> id}
    end

    defp doc(id, user, channel, extra \\ %{}) do
      Map.merge(
        %{
          "_id" => id,
          "channel_id" => channel,
          "user_id" => user,
          "name" => "a.png",
          "content_type" => "image/png",
          "size" => 10,
          "path" => "#{channel}/#{id}.png",
          "url" => "https://cdn.test/#{id}.png",
          "uploaded_at" => DateTime.utc_now() |> DateTime.truncate(:millisecond),
          "message_id" => nil
        },
        extra
      )
    end

    defp seed(user, channel, count) do
      for n <- 1..count do
        id = "att-#{System.unique_integer([:positive])}-#{n}"
        :ok = Repo.insert_attachment(doc(id, user, channel))
        id
      end
    end

    defp fetch(id), do: Mongo.find_one(Messaging.Mongo, "attachments", %{"_id" => id})

    test "pending attachments of a user are counted", %{user: user, channel: channel} do
      assert {:ok, 0} = Repo.count_pending_attachments(user)
      seed(user, channel, 3)
      assert {:ok, 3} = Repo.count_pending_attachments(user)
    end

    test "claiming gives the files to one message, in the order asked", %{
      user: user,
      channel: channel
    } do
      [first, second] = seed(user, channel, 2)

      assert {:ok, [%{"_id" => ^second}, %{"_id" => ^first}]} =
               Repo.claim_attachments([second, first], user, channel, "msg-1")

      assert %{"message_id" => "msg-1"} = fetch(first)
      assert {:ok, 0} = Repo.count_pending_attachments(user)
    end

    test "a claimed file cannot be claimed again by another message", %{
      user: user,
      channel: channel
    } do
      [id] = seed(user, channel, 1)

      assert {:ok, [_one]} = Repo.claim_attachments([id], user, channel, "msg-1")
      assert {:error, :invalid_attachment} = Repo.claim_attachments([id], user, channel, "msg-2")
      assert %{"message_id" => "msg-1"} = fetch(id)
    end

    test "a file of another user or of another channel cannot be claimed", %{
      user: user,
      channel: channel
    } do
      [id] = seed(user, channel, 1)

      assert {:error, :invalid_attachment} =
               Repo.claim_attachments([id], "intruder", channel, "msg-1")

      assert {:error, :invalid_attachment} =
               Repo.claim_attachments([id], user, "other-chan", "msg-1")

      assert %{"message_id" => nil} = fetch(id)
    end

    test "claiming is all or nothing: one bad id leaves the good ones free", %{
      user: user,
      channel: channel
    } do
      [good] = seed(user, channel, 1)

      assert {:error, :invalid_attachment} =
               Repo.claim_attachments([good, "does-not-exist"], user, channel, "msg-1")

      assert %{"message_id" => nil} = fetch(good)
    end

    test "claiming nothing is fine", %{user: user, channel: channel} do
      assert {:ok, []} = Repo.claim_attachments([], user, channel, "msg-1")
    end

    test "a released claim can be used again", %{user: user, channel: channel} do
      [id] = seed(user, channel, 1)
      {:ok, _} = Repo.claim_attachments([id], user, channel, "msg-1")

      assert :ok = Repo.release_attachments("msg-1")
      assert {:ok, [_one]} = Repo.claim_attachments([id], user, channel, "msg-2")
    end

    test "files of a deleted message are marked and then picked up by the cleaner", %{
      user: user,
      channel: channel
    } do
      [id] = seed(user, channel, 1)
      {:ok, _} = Repo.claim_attachments([id], user, channel, "msg-1")
      long_ago = DateTime.add(DateTime.utc_now(), -7200, :second)

      assert {:ok, docs} = Repo.list_cleanable_attachments(long_ago, 1000)
      refute Enum.any?(docs, &(&1["_id"] == id))

      assert :ok = Repo.orphan_message_attachments("msg-1", DateTime.utc_now())

      assert {:ok, docs} = Repo.list_cleanable_attachments(long_ago, 1000)
      assert Enum.any?(docs, &(&1["_id"] == id))
    end

    test "uploads that were never sent are cleaned only once they are old", %{
      user: user,
      channel: channel
    } do
      [fresh] = seed(user, channel, 1)
      old_id = "old-#{System.unique_integer([:positive])}"

      old_at =
        DateTime.add(DateTime.utc_now(), -48 * 3600, :second) |> DateTime.truncate(:millisecond)

      draft_id = "draft-#{System.unique_integer([:positive])}"

      draft_at =
        DateTime.add(DateTime.utc_now(), -23 * 3600, :second) |> DateTime.truncate(:millisecond)

      :ok = Repo.insert_attachment(doc(old_id, user, channel, %{"uploaded_at" => old_at}))
      :ok = Repo.insert_attachment(doc(draft_id, user, channel, %{"uploaded_at" => draft_at}))
      day_ago = DateTime.add(DateTime.utc_now(), -24 * 3600, :second)

      assert {:ok, docs} = Repo.list_cleanable_attachments(day_ago, 1000)
      ids = Enum.map(docs, & &1["_id"])

      assert old_id in ids
      refute fresh in ids
      refute draft_id in ids
    end

    test "a claimed file that is in use is never cleaned, however old", %{
      user: user,
      channel: channel
    } do
      id = "used-#{System.unique_integer([:positive])}"

      old_at =
        DateTime.add(DateTime.utc_now(), -86_400, :second) |> DateTime.truncate(:millisecond)

      :ok = Repo.insert_attachment(doc(id, user, channel, %{"uploaded_at" => old_at}))
      {:ok, _} = Repo.claim_attachments([id], user, channel, "msg-1")

      assert {:ok, docs} = Repo.list_cleanable_attachments(DateTime.utc_now(), 1000)
      refute Enum.any?(docs, &(&1["_id"] == id))
    end

    test "deleting a channel marks every file of that channel", %{user: user, channel: channel} do
      [pending] = seed(user, channel, 1)
      [used] = seed(user, channel, 1)
      {:ok, _} = Repo.claim_attachments([used], user, channel, "msg-1")
      :ok = Repo.upsert_channel(%{"_id" => channel, "server_id" => "srv-x", "kind" => "text"})

      assert :ok = Repo.delete_channel(channel)

      assert %{"orphaned_at" => %DateTime{}} = fetch(pending)
      assert %{"orphaned_at" => %DateTime{}} = fetch(used)
    end

    test "deleting a server marks the files of all its channels", %{user: user} do
      server = "srv-" <> Messaging.UUID.generate()
      [channel_a, channel_b] = for n <- 1..2, do: "chan-#{n}-" <> Messaging.UUID.generate()
      [a] = seed(user, channel_a, 1)
      [b] = seed(user, channel_b, 1)

      assert :ok = Repo.delete_server_data(server, [channel_a, channel_b])

      assert %{"orphaned_at" => %DateTime{}} = fetch(a)
      assert %{"orphaned_at" => %DateTime{}} = fetch(b)
    end

    test "deleting a message empties its attachments in the message itself", %{channel: channel} do
      message_id = "msg-" <> Messaging.UUID.generate()

      {:ok, _} =
        Repo.insert_message(%{
          "_id" => message_id,
          "channel_id" => channel,
          "server_id" => "srv-1",
          "user_id" => "user-1",
          "content" => "hola",
          "inserted_at" => DateTime.utc_now() |> DateTime.truncate(:millisecond),
          "attachments" => [%{"id" => "a1", "url" => "https://cdn.test/a1.png"}]
        })

      assert {:ok, %{"attachments" => [], "content" => ""}} =
               Repo.delete_message(message_id, channel, DateTime.utc_now())
    end

    test "records are removed by id", %{user: user, channel: channel} do
      [id] = seed(user, channel, 1)

      assert :ok = Repo.delete_attachments([id])
      assert nil == fetch(id)
    end

    test "ensure_indexes/0 builds the attachment indexes" do
      assert :ok = Repo.ensure_indexes()

      {:ok, %{"cursor" => %{"firstBatch" => indexes}}} =
        Mongo.command(Messaging.Mongo, listIndexes: "attachments")

      names = Enum.map(indexes, & &1["name"])
      assert "attachments_user_message" in names
      assert "attachments_orphaned_at" in names
    end
  end
else
  defmodule Messaging.Chat.Repo.AttachmentsMongoTest do
    use ExUnit.Case

    test "skipped: set MONGO_URL to run this against a real Mongo instance" do
      IO.puts("\nSkipping attachments Mongo test: MONGO_URL not set.\n")
    end
  end
end
