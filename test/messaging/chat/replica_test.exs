defmodule Messaging.Chat.ReplicaTest do
  use ExUnit.Case, async: true
  import Mox

  alias Messaging.Chat.Replica
  alias Messaging.ReplicaFixtures, as: Fixtures

  setup :verify_on_exit!

  @channels ~w(general staff random)

  defp stub_server(owner, overrides_by_channel) do
    stub(Messaging.Chat.RepoMock, :get_server_owner, fn "srv-1" -> owner end)
    stub(Messaging.Chat.RepoMock, :list_roles, fn "srv-1" -> {:ok, Fixtures.roles()} end)

    stub(Messaging.Chat.RepoMock, :list_channel_overrides, fn @channels ->
      {:ok, overrides_by_channel}
    end)
  end

  defp hidden_from_everyone, do: Fixtures.override("everyone", [], ["VIEW_CHANNELS"])

  defp viewable(user_id, role_ids),
    do: Replica.viewable_channel_ids("srv-1", user_id, role_ids, @channels)

  describe "viewable_channel_ids/4" do
    test "a regular member sees the open channels, in order, but not the hidden ones" do
      stub_server("owner-1", %{"staff" => [hidden_from_everyone()]})

      assert {:ok, ["general", "random"]} = viewable("ana", ["everyone"])
    end

    test "a role override shows a hidden channel only to the people who hold that role" do
      stub_server("owner-1", %{
        "staff" => [hidden_from_everyone(), Fixtures.override("mod", ["VIEW_CHANNELS"], [])]
      })

      assert {:ok, ["general", "staff", "random"]} = viewable("ana", ["everyone", "mod"])
      assert {:ok, ["general", "random"]} = viewable("beto", ["everyone"])
    end

    test "the owner and administrators see every channel, whatever the overrides say" do
      everywhere = Map.new(@channels, &{&1, [hidden_from_everyone()]})
      stub_server("owner-1", everywhere)

      assert {:ok, @channels} = viewable("owner-1", ["everyone"])
      assert {:ok, @channels} = viewable("ana", ["everyone", "admin"])
      assert {:ok, []} = viewable("beto", ["everyone"])
    end

    test "roles that no longer exist grant nothing" do
      stub_server("owner-1", %{})

      assert {:ok, []} = viewable("ana", ["deleted-role"])
    end

    test "with no channels it answers without reading anything" do
      expect(Messaging.Chat.RepoMock, :get_server_owner, 0, fn _server -> "owner-1" end)
      expect(Messaging.Chat.RepoMock, :list_channel_overrides, 0, fn _ids -> {:ok, %{}} end)

      assert {:ok, []} = Replica.viewable_channel_ids("srv-1", "ana", ["everyone"], [])
    end

    test "a failing read is returned, never read as 'no channels'" do
      stub(Messaging.Chat.RepoMock, :get_server_owner, fn _server -> {:error, :timeout} end)
      assert {:error, :timeout} = viewable("ana", ["everyone"])

      stub_server("owner-1", %{})
      stub(Messaging.Chat.RepoMock, :list_channel_overrides, fn _ids -> {:error, :timeout} end)
      assert {:error, :timeout} = viewable("ana", ["everyone"])
    end
  end
end
