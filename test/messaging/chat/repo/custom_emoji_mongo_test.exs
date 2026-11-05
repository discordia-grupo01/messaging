mongo_url = System.get_env("MONGO_URL")

if mongo_url do
  defmodule Messaging.Chat.Repo.CustomEmojiMongoTest do
    use ExUnit.Case, async: false

    alias Messaging.Chat.Repo.Mongo, as: Repo

    setup do
      id = Messaging.UUID.generate()
      server_id = Messaging.UUID.generate()

      {:ok,
       id: id,
       server_id: server_id,
       emoji: %{
         "_id" => id,
         "server_id" => server_id,
         "name" => "party",
         "animated" => true,
         "image_url" => "https://cdn.test/party.gif"
       }}
    end

    defp fetch(id) do
      {:ok, [doc]} = Repo.get_custom_emojis([id])
      doc
    end

    test "a created emoji is active", %{id: id, emoji: emoji} do
      assert :ok = Repo.apply_emoji_created(emoji)

      assert %{"name" => "party", "animated" => true, "deleted" => false} = fetch(id)
    end

    test "a repeated event changes nothing", %{id: id, emoji: emoji} do
      :ok = Repo.apply_emoji_created(emoji)
      assert :ok = Repo.apply_emoji_created(emoji)
      assert %{"deleted" => false} = fetch(id)
    end

    test "deleting keeps the data for old content", %{id: id, emoji: emoji} do
      :ok = Repo.apply_emoji_created(emoji)
      assert :ok = Repo.apply_emoji_deleted(emoji)

      assert %{"deleted" => true, "image_url" => "https://cdn.test/party.gif"} = fetch(id)
    end

    test "the deletion wins when it arrives first", %{id: id, emoji: emoji} do
      assert :ok = Repo.apply_emoji_deleted(emoji)
      assert :ok = Repo.apply_emoji_created(emoji)

      assert %{"deleted" => true} = fetch(id)
    end

    test "no ids looks nothing up" do
      assert {:ok, []} = Repo.get_custom_emojis([])
    end

    test "deleting the server removes its emojis", %{id: id, server_id: server_id, emoji: emoji} do
      :ok = Repo.apply_emoji_created(emoji)

      assert :ok = Repo.delete_server_data(server_id, [])
      assert {:ok, []} = Repo.get_custom_emojis([id])
    end
  end
end
