mongo_url = System.get_env("MONGO_URL")

if mongo_url do
  defmodule Messaging.Chat.Repo.ServerBoostsMongoTest do
    use ExUnit.Case, async: false

    alias Messaging.Chat.Repo.Mongo, as: Repo

    setup do
      {:ok, server: Messaging.UUID.generate()}
    end

    test "a server without events is level 0", %{server: server} do
      assert Repo.server_boost_level(server) == 0
    end

    test "the level follows the version, up and down", %{server: server} do
      assert {:ok, :applied} = Repo.apply_server_boost(server, 2, 1)
      assert Repo.server_boost_level(server) == 2

      assert {:ok, :applied} = Repo.apply_server_boost(server, 1, 2)
      assert Repo.server_boost_level(server) == 1
    end

    test "a repeated or older event doesn't change the level", %{server: server} do
      {:ok, :applied} = Repo.apply_server_boost(server, 2, 4)

      assert {:ok, :stale} = Repo.apply_server_boost(server, 3, 4)
      assert {:ok, :stale} = Repo.apply_server_boost(server, 0, 3)
      assert Repo.server_boost_level(server) == 2
    end

    test "deleting the server forgets its level", %{server: server} do
      {:ok, :applied} = Repo.apply_server_boost(server, 3, 1)

      assert :ok = Repo.delete_server_data(server, [])
      assert Repo.server_boost_level(server) == 0
    end
  end
end
