mongo_url = System.get_env("MONGO_URL")

if mongo_url do
  defmodule Messaging.Chat.Repo.OutboxApplyMongoTest do
    use ExUnit.Case, async: false

    alias Messaging.Chat.Repo.Mongo, as: Repo

    setup do
      id = "msg-" <> Messaging.UUID.generate()
      {:ok, id: id, channel: "chan-" <> Messaging.UUID.generate()}
    end

    defp doc(id, channel, extra \\ %{}) do
      Map.merge(
        %{
          "_id" => id,
          "channel_id" => channel,
          "server_id" => "srv-1",
          "user_id" => "user-1",
          "content" => "hola",
          "inserted_at" => ~U[2026-10-13 12:00:00.000Z]
        },
        extra
      )
    end

    test "upserting a message that does not exist creates it", %{id: id, channel: channel} do
      assert :ok = Repo.upsert_message(doc(id, channel))

      assert %{"_id" => ^id, "content" => "hola", "inserted_at" => ~U[2026-10-13 12:00:00.000Z]} =
               Repo.get_message(id)
    end

    test "upserting twice is harmless and never overwrites what is already there", %{
      id: id,
      channel: channel
    } do
      :ok = Repo.upsert_message(doc(id, channel))
      :ok = Repo.upsert_message(doc(id, channel, %{"content" => "otro"}))

      assert %{"content" => "hola"} = Repo.get_message(id)
    end

    test "an edit applied after a later one does not undo it", %{id: id, channel: channel} do
      :ok = Repo.upsert_message(doc(id, channel))

      assert :ok =
               Repo.apply_message_update(id, channel, %{
                 "content" => "editado",
                 "edited_at" => ~U[2026-10-13 12:05:00.000Z],
                 "changed_at" => ~U[2026-10-13 12:05:00.000Z]
               })

      assert %{"content" => "editado", "edited_at" => ~U[2026-10-13 12:05:00.000Z]} =
               Repo.get_message(id)
    end

    test "an edit never revives a deleted message", %{id: id, channel: channel} do
      :ok = Repo.upsert_message(doc(id, channel))
      {:ok, _} = Repo.delete_message(id, channel, ~U[2026-10-13 12:10:00.000Z])

      assert :ok = Repo.apply_message_update(id, channel, %{"content" => "zombi"})

      assert %{"content" => "", "deleted_at" => ~U[2026-10-13 12:10:00.000Z]} =
               Repo.get_message(id)
    end

    test "an edit of a message from another channel changes nothing", %{id: id, channel: channel} do
      :ok = Repo.upsert_message(doc(id, channel))

      assert :ok = Repo.apply_message_update(id, "other-channel", %{"content" => "robado"})

      assert %{"content" => "hola"} = Repo.get_message(id)
    end

    test "the whole sequence can be replayed with the same result", %{id: id, channel: channel} do
      steps = fn ->
        :ok = Repo.upsert_message(doc(id, channel))
        :ok = Repo.apply_message_update(id, channel, %{"content" => "editado"})
        {:ok, _} = Repo.delete_message(id, channel, ~U[2026-10-13 12:10:00.000Z])
      end

      steps.()
      first = Repo.get_message(id)
      steps.()

      assert Repo.get_message(id) == first
    end
  end
else
  defmodule Messaging.Chat.Repo.OutboxApplyMongoTest do
    use ExUnit.Case

    test "skipped: set MONGO_URL to run this against a real Mongo instance" do
      IO.puts("\nSkipping outbox apply Mongo test: MONGO_URL not set.\n")
    end
  end
end
