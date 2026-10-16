mongo_url = System.get_env("MONGO_URL")

if mongo_url do
  defmodule Messaging.Chat.Repo.SuspensionMongoTest do
    use ExUnit.Case, async: false

    alias Messaging.Chat.Repo.Mongo, as: Repo

    setup do
      {:ok, user: Messaging.UUID.generate()}
    end

    test "a user nobody mentioned is not suspended", %{user: user} do
      assert Repo.suspended?(user) == false
    end

    test "suspending and reactivating follow the version", %{user: user} do
      assert {:ok, :applied} = Repo.apply_suspension(user, true, 1)
      assert Repo.suspended?(user) == true

      assert {:ok, :applied} = Repo.apply_suspension(user, false, 2)
      assert Repo.suspended?(user) == false
    end

    test "a repeated or older event does not change the state", %{user: user} do
      {:ok, :applied} = Repo.apply_suspension(user, true, 4)

      assert {:ok, :stale} = Repo.apply_suspension(user, true, 4)
      assert {:ok, :stale} = Repo.apply_suspension(user, false, 3)
      assert Repo.suspended?(user) == true
    end

    test "a reactivation that arrives before the suspension it follows wins", %{user: user} do
      assert {:ok, :applied} = Repo.apply_suspension(user, false, 2)
      assert {:ok, :stale} = Repo.apply_suspension(user, true, 1)
      assert Repo.suspended?(user) == false
    end

    test "the document keeps user id, state, version and update time", %{user: user} do
      {:ok, :applied} = Repo.apply_suspension(user, true, 9)

      assert %{
               "_id" => ^user,
               "suspended" => true,
               "version" => 9,
               "updated_at" => %DateTime{}
             } = Mongo.find_one(Messaging.Mongo, "suspended_users", %{"_id" => user})
    end
  end
else
  defmodule Messaging.Chat.Repo.SuspensionMongoTest do
    use ExUnit.Case

    test "skipped: set MONGO_URL to run this against a real Mongo instance" do
      IO.puts("\nSkipping suspension Mongo test: MONGO_URL not set.\n")
    end
  end
end
