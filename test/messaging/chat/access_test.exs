defmodule Messaging.Chat.AccessTest do
  use ExUnit.Case, async: true
  import Mox

  alias Messaging.Chat.{Access, ChannelCache}

  setup :verify_on_exit!

  defp dm,
    do: %ChannelCache{
      channel_id: "dm-1",
      server_id: nil,
      name: "",
      kind: "dm",
      participants: ["a", "b"]
    }

  defp text,
    do: %ChannelCache{channel_id: "c-1", server_id: "srv-1", name: "general", kind: "text"}

  test "for_channel/1 picks the strategy by kind" do
    assert Access.for_channel(dm()) == Access.Direct
    assert Access.for_channel(text()) == Access.Server
  end

  describe "Direct" do
    setup do
      stub(Messaging.Chat.RepoMock, :get_blocks, fn _ids -> {:ok, []} end)
      :ok
    end

    test "a participant can view and post" do
      assert {:ok, true} = Access.Direct.can_view?(dm(), "a")
      assert {:ok, true} = Access.Direct.can_post?(dm(), "b")
    end

    test "a stranger gets the same answer as for a conversation that does not exist" do
      assert {:error, :channel_not_found} = Access.Direct.can_view?(dm(), "intruder")
      assert {:error, :channel_not_found} = Access.Direct.can_post?(dm(), "intruder")
    end

    test "a block in either direction stops posting but not viewing" do
      expect(Messaging.Chat.RepoMock, :get_blocks, fn _ids -> {:ok, [%{"_id" => "b:a"}]} end)
      assert {:ok, false} = Access.Direct.can_post?(dm(), "a")

      expect(Messaging.Chat.RepoMock, :get_blocks, fn _ids -> {:ok, [%{"_id" => "a:b"}]} end)
      assert {:ok, false} = Access.Direct.can_post?(dm(), "b")

      assert {:ok, true} = Access.Direct.can_view?(dm(), "a")
      assert {:ok, true} = Access.Direct.can_view?(dm(), "b")
    end

    test "deleting follows the same rule as posting: a block freezes the conversation" do
      expect(Messaging.Chat.RepoMock, :get_blocks, fn _ids -> {:ok, [%{"_id" => "b:a"}]} end)
      assert {:ok, false} = Access.Direct.can_delete?(dm(), "a")

      expect(Messaging.Chat.RepoMock, :get_blocks, fn _ids -> {:ok, []} end)
      assert {:ok, true} = Access.Direct.can_delete?(dm(), "a")

      assert {:error, :channel_not_found} = Access.Direct.can_delete?(dm(), "intruder")
    end

    test "a failing block lookup is propagated, not read as 'allowed'" do
      expect(Messaging.Chat.RepoMock, :get_blocks, fn _ids -> {:error, :timeout} end)

      assert {:error, :timeout} = Access.Direct.can_post?(dm(), "a")
    end

    test "reacting follows the same rule as posting" do
      expect(Messaging.Chat.RepoMock, :get_blocks, fn _ids -> {:ok, [%{"_id" => "b:a"}]} end)
      assert {:ok, false} = Access.Direct.can_react?(dm(), "a")

      expect(Messaging.Chat.RepoMock, :get_blocks, fn _ids -> {:ok, []} end)
      assert {:ok, true} = Access.Direct.can_react?(dm(), "a")

      assert {:error, :channel_not_found} = Access.Direct.can_react?(dm(), "intruder")
    end

    test "nobody moderates a direct conversation" do
      assert {:ok, false} = Access.Direct.can_moderate?(dm(), "a")
    end
  end

  describe "Server" do
    test "asks servers for each permission in that channel" do
      expect(Messaging.Chat.PermissionsStoreMock, :can_view_channel?, 2, fn _channel, "u" ->
        {:ok, true}
      end)

      expect(Messaging.Chat.PermissionsStoreMock, :can_send_messages?, fn _channel, "u" ->
        {:ok, false}
      end)

      expect(Messaging.Chat.PermissionsStoreMock, :can_manage_messages?, fn _channel, "u" ->
        {:ok, true}
      end)

      assert {:ok, true} = Access.Server.can_view?(text(), "u")
      assert {:ok, true} = Access.Server.can_delete?(text(), "u")
      assert {:ok, false} = Access.Server.can_post?(text(), "u")
      assert {:ok, true} = Access.Server.can_moderate?(text(), "u")
    end

    test "reacting asks servers for ADD_REACTIONS in that channel" do
      expect(Messaging.Chat.PermissionsStoreMock, :can_add_reactions?, fn %{channel_id: _}, "u" ->
        {:ok, false}
      end)

      assert {:ok, false} = Access.Server.can_react?(text(), "u")
    end
  end
end
