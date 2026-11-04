mongo_url = System.get_env("MONGO_URL")

if mongo_url do
  defmodule Messaging.Chat.Repo.PremiumMongoTest do
    use ExUnit.Case, async: false

    alias Messaging.Chat.Repo.Mongo, as: Repo

    setup do
      {:ok, user: Messaging.UUID.generate()}
    end

    test "a user without events is not Premium", %{user: user} do
      assert Repo.premium?(user) == false
    end

    test "activating and deactivating follow the version", %{user: user} do
      assert {:ok, :applied} = Repo.apply_premium(user, true, 1)
      assert Repo.premium?(user) == true

      assert {:ok, :applied} = Repo.apply_premium(user, false, 2)
      assert Repo.premium?(user) == false
    end

    test "a repeated or older event does not change the state", %{user: user} do
      {:ok, :applied} = Repo.apply_premium(user, true, 4)

      assert {:ok, :stale} = Repo.apply_premium(user, true, 4)
      assert {:ok, :stale} = Repo.apply_premium(user, false, 3)
      assert Repo.premium?(user) == true
    end
  end
end
