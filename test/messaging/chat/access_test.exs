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
      assert {:ok, true} = Access.Direct.can_view?(dm(), "a", "jwt")
      assert {:ok, true} = Access.Direct.can_post?(dm(), "b", "jwt")
    end

    test "a stranger gets the same answer as for a conversation that does not exist" do
      assert {:error, :channel_not_found} = Access.Direct.can_view?(dm(), "intruder", "jwt")
      assert {:error, :channel_not_found} = Access.Direct.can_post?(dm(), "intruder", "jwt")
    end

    test "a block in either direction stops posting but not viewing" do
      expect(Messaging.Chat.RepoMock, :get_blocks, fn _ids -> {:ok, [%{"_id" => "b:a"}]} end)
      assert {:ok, false} = Access.Direct.can_post?(dm(), "a", "jwt")

      expect(Messaging.Chat.RepoMock, :get_blocks, fn _ids -> {:ok, [%{"_id" => "a:b"}]} end)
      assert {:ok, false} = Access.Direct.can_post?(dm(), "b", "jwt")

      assert {:ok, true} = Access.Direct.can_view?(dm(), "a", "jwt")
      assert {:ok, true} = Access.Direct.can_view?(dm(), "b", "jwt")
    end

    test "deleting follows the same rule as posting: a block freezes the conversation" do
      expect(Messaging.Chat.RepoMock, :get_blocks, fn _ids -> {:ok, [%{"_id" => "b:a"}]} end)
      assert {:ok, false} = Access.Direct.can_delete?(dm(), "a", "jwt")

      expect(Messaging.Chat.RepoMock, :get_blocks, fn _ids -> {:ok, []} end)
      assert {:ok, true} = Access.Direct.can_delete?(dm(), "a", "jwt")

      assert {:error, :channel_not_found} = Access.Direct.can_delete?(dm(), "intruder", "jwt")
    end

    test "a failing block lookup is propagated, not read as 'allowed'" do
      expect(Messaging.Chat.RepoMock, :get_blocks, fn _ids -> {:error, :timeout} end)

      assert {:error, :timeout} = Access.Direct.can_post?(dm(), "a", "jwt")
    end

    test "nobody moderates a direct conversation" do
      assert {:ok, false} = Access.Direct.can_moderate?(dm(), "a", "jwt")
    end
  end

  describe "Server" do
    test "asks servers for each permission in that channel" do
      expect(Messaging.Chat.PermissionsClientMock, :can_view_channel?, 2, fn "c-1",
                                                                             "u",
                                                                             "jwt" ->
        {:ok, true}
      end)

      expect(Messaging.Chat.PermissionsClientMock, :can_send_messages?, fn "c-1", "u", "jwt" ->
        {:ok, false}
      end)

      expect(Messaging.Chat.PermissionsClientMock, :can_manage_messages?, fn "c-1",
                                                                             "u",
                                                                             "jwt" ->
        {:ok, true}
      end)

      assert {:ok, true} = Access.Server.can_view?(text(), "u", "jwt")
      assert {:ok, true} = Access.Server.can_delete?(text(), "u", "jwt")
      assert {:ok, false} = Access.Server.can_post?(text(), "u", "jwt")
      assert {:ok, true} = Access.Server.can_moderate?(text(), "u", "jwt")
    end
  end
end
