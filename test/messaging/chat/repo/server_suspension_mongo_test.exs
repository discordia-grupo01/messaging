mongo_url = System.get_env("MONGO_URL")

if mongo_url do
  defmodule Messaging.Chat.Repo.ServerSuspensionMongoTest do
    use ExUnit.Case, async: false

    alias Messaging.Chat.Repo.Mongo, as: Repo

    setup do
      {:ok, server: Messaging.UUID.generate()}
    end

    test "a server nobody suspended is active", %{server: server} do
      assert Repo.server_suspended?(server) == false
    end

    test "suspending and reactivating follow the version", %{server: server} do
      assert {:ok, :applied} = Repo.apply_server_suspension(server, true, 1)
      assert Repo.server_suspended?(server) == true

      assert {:ok, :applied} = Repo.apply_server_suspension(server, false, 2)
      assert Repo.server_suspended?(server) == false
    end

    test "a repeated or older event does not change the state", %{server: server} do
      {:ok, :applied} = Repo.apply_server_suspension(server, true, 4)

      assert {:ok, :stale} = Repo.apply_server_suspension(server, true, 4)
      assert {:ok, :stale} = Repo.apply_server_suspension(server, false, 3)
      assert Repo.server_suspended?(server) == true
    end

    test "a reactivation that arrives before the suspension it follows wins", %{server: server} do
      assert {:ok, :applied} = Repo.apply_server_suspension(server, false, 2)
      assert {:ok, :stale} = Repo.apply_server_suspension(server, true, 1)
      assert Repo.server_suspended?(server) == false
    end

    test "servers do not share state", %{server: server} do
      other = Messaging.UUID.generate()
      {:ok, :applied} = Repo.apply_server_suspension(server, true, 1)

      assert Repo.server_suspended?(other) == false
    end

    test "a server and a user with the same id do not collide", %{server: server} do
      {:ok, :applied} = Repo.apply_server_suspension(server, true, 1)

      assert Repo.suspended?(server) == false
    end

    test "the document keeps server id, state, version and update time", %{server: server} do
      {:ok, :applied} = Repo.apply_server_suspension(server, true, 9)

      assert %{
               "_id" => ^server,
               "suspended" => true,
               "version" => 9,
               "updated_at" => %DateTime{}
             } = Mongo.find_one(Messaging.Mongo, "suspended_servers", %{"_id" => server})
    end
  end
else
  defmodule Messaging.Chat.Repo.ServerSuspensionMongoTest do
    use ExUnit.Case

    test "skipped: set MONGO_URL to run this against a real Mongo instance" do
      IO.puts("\nSkipping server suspension Mongo test: MONGO_URL not set.\n")
    end
  end
end
