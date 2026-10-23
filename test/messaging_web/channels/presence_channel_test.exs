defmodule MessagingWeb.PresenceChannelTest do
  use MessagingWeb.ChannelCase
  import ExUnit.CaptureLog
  import Mox

  alias Messaging.AuthFixtures
  alias MessagingWeb.PresenceChannel

  setup :set_mox_global
  setup :verify_on_exit!

  @ana "11111111-1111-4111-8111-111111111111"
  @beto "22222222-2222-4222-8222-222222222222"
  @cami "33333333-3333-4333-8333-333333333333"
  @topic "presence:srv-1"

  defp online(user_id, version),
    do: %{
      "_id" => user_id,
      "manual" => "online",
      "connections" => [%{"id" => "c", "instance" => "i", "idle" => false}],
      "version" => version
    }

  setup do
    stub(Messaging.Chat.RepoMock, :get_member, fn "srv-1", user_id -> %{"user_id" => user_id} end)

    stub(Messaging.Chat.RepoMock, :list_members, fn "srv-1" ->
      {:ok, [%{"user_id" => @ana}, %{"user_id" => @beto}, %{"user_id" => @cami}]}
    end)

    stub(Messaging.Presence.StoreMock, :get_many, fn _ids ->
      {:ok, [online(@ana, 1), online(@beto, 4)]}
    end)

    stub(Messaging.Chat.RepoMock, :get_blocks, fn _ids -> {:ok, []} end)
    :ok
  end

  defp socket_for(user_id) do
    stub(Messaging.Auth.TicketStoreMock, :take, fn _id ->
      {:ok, AuthFixtures.ticket_doc(user_id)}
    end)

    {:ok, socket} = connect(MessagingWeb.UserSocket, %{"ticket" => "a-ticket"})
    socket
  end

  defp join_as(user_id), do: subscribe_and_join(socket_for(user_id), PresenceChannel, @topic)

  defp block_between(a, b) do
    stub(Messaging.Chat.RepoMock, :get_blocks, fn ids ->
      if (a <> ":" <> b) in ids,
        do: {:ok, [%{"_id" => a <> ":" <> b, "blocker_id" => a, "blocked_id" => b}]},
        else: {:ok, []}
    end)
  end

  describe "join" do
    test "CA1: a member gets who is not offline in the server, with their versions" do
      assert {:ok, %{"presences" => presences}, _socket} = join_as(@ana)

      assert presences == [
               %{"user_id" => @ana, "status" => "online", "version" => 1},
               %{"user_id" => @beto, "status" => "online", "version" => 4}
             ]
    end

    test "a member with a block with me shows offline, so it is not listed" do
      block_between(@beto, @ana)

      assert {:ok, %{"presences" => [%{"user_id" => @ana}]}, _socket} = join_as(@ana)
    end

    test "who is not a member of the server cannot see it" do
      stub(Messaging.Chat.RepoMock, :get_member, fn "srv-1", _user_id -> nil end)

      assert {:error, %{error: %{code: "FORBIDDEN"}}} = join_as(@ana)
    end

    test "a user suspended after connecting cannot join" do
      socket = socket_for(@ana)
      Messaging.SuspensionHelper.stub_suspended(@ana)

      assert {:error, %{error: %{code: "ACCOUNT_SUSPENDED"}}} =
               subscribe_and_join(socket, PresenceChannel, @topic)
    end

    test "a store failure answers PRESENCE_UNAVAILABLE" do
      stub(Messaging.Presence.StoreMock, :get_many, fn _ids -> {:error, :timeout} end)

      log =
        capture_log(fn ->
          assert {:error, %{error: %{code: "PRESENCE_UNAVAILABLE"}}} = join_as(@ana)
        end)

      assert log =~ "presence_join_failed"
    end
  end

  describe "presence_updated" do
    test "CA1, CA2, CA4: changes of the members reach whoever is looking at the server" do
      {:ok, _reply, _socket} = join_as(@ana)

      for status <- ["idle", "dnd", "offline"] do
        payload = %{"user_id" => @beto, "status" => status, "version" => 9}
        MessagingWeb.Endpoint.broadcast!(@topic, "presence_updated", payload)
        assert_push "presence_updated", ^payload
      end
    end

    test "the changes of someone with a block with me are not delivered" do
      {:ok, _reply, _socket} = join_as(@ana)
      block_between(@ana, @cami)

      MessagingWeb.Endpoint.broadcast!(@topic, "presence_updated", %{
        "user_id" => @cami,
        "status" => "online",
        "version" => 2
      })

      refute_push "presence_updated", _payload
    end

    test "whether there is a block is asked once and then cached" do
      {:ok, _reply, _socket} = join_as(@ana)

      expect(Messaging.Chat.RepoMock, :get_blocks, 1, fn _ids -> {:ok, []} end)

      for version <- 1..3 do
        payload = %{"user_id" => @beto, "status" => "online", "version" => version}
        MessagingWeb.Endpoint.broadcast!(@topic, "presence_updated", payload)
        assert_push "presence_updated", ^payload
      end
    end

    test "if the blocks cannot be read the update is not shown" do
      {:ok, _reply, _socket} = join_as(@ana)
      stub(Messaging.Chat.RepoMock, :get_blocks, fn _ids -> {:error, :timeout} end)

      MessagingWeb.Endpoint.broadcast!(@topic, "presence_updated", %{
        "user_id" => @beto,
        "status" => "online",
        "version" => 2
      })

      refute_push "presence_updated", _payload
    end

    test "my own changes reach me without asking for blocks" do
      {:ok, _reply, _socket} = join_as(@ana)
      expect(Messaging.Chat.RepoMock, :get_blocks, 0, fn _ids -> {:ok, []} end)

      payload = %{"user_id" => @ana, "status" => "idle", "version" => 3}
      MessagingWeb.Endpoint.broadcast!(@topic, "presence_updated", payload)
      assert_push "presence_updated", ^payload
    end
  end

  describe "access_revoked" do
    test "leaving the server closes the presence of that server" do
      {:ok, _reply, socket} = join_as(@ana)
      Process.unlink(socket.channel_pid)
      ref = Process.monitor(socket.channel_pid)

      MessagingWeb.Endpoint.broadcast!(@topic, "access_revoked", %{
        "server_id" => "srv-1",
        "reason" => "member_left",
        "user_id" => @ana
      })

      assert_push "access_revoked", %{"server_id" => "srv-1", "reason" => "member_left"}
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}
    end

    test "someone else leaving does not close mine" do
      {:ok, _reply, socket} = join_as(@ana)

      MessagingWeb.Endpoint.broadcast!(@topic, "access_revoked", %{
        "server_id" => "srv-1",
        "reason" => "member_left",
        "user_id" => @beto
      })

      refute_push "access_revoked", _payload
      assert Process.alive?(socket.channel_pid)
    end
  end

  test "nothing can be sent on this channel" do
    {:ok, _reply, socket} = join_as(@ana)

    ref = push(socket, "set_status", %{"status" => "dnd"})
    assert_reply ref, :error, %{error: %{code: "INVALID_PAYLOAD"}}
  end
end
