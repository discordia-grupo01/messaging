defmodule MessagingWeb.UserChannelPresenceTest do
  use MessagingWeb.ChannelCase
  import ExUnit.CaptureLog
  import Mox

  alias Messaging.AuthFixtures
  alias Messaging.Presence.Tracker
  alias MessagingWeb.UserChannel

  setup :set_mox_global
  setup :verify_on_exit!

  @ana "11111111-1111-4111-8111-111111111111"

  setup do
    test_pid = self()

    stub(Messaging.Presence.StoreMock, :heartbeat, fn _id, _at -> :ok end)
    stub(Messaging.Presence.StoreMock, :delete_instance, fn _id -> :ok end)
    stub(Messaging.Presence.StoreMock, :member_server_ids, fn _ -> {:ok, ["srv-1"]} end)
    stub(Messaging.Presence.StoreMock, :dm_partner_ids, fn _, _ -> {:ok, []} end)

    stub(Messaging.Presence.StoreMock, :change, fn user_id, change ->
      send(test_pid, {:change, user_id, change})
      {:ok, {:changed, %{"manual" => "dnd", "connections" => [], "version" => 6}}}
    end)

    stub(Messaging.EventPublisherMock, :publish_event, fn _id, topic, event, payload ->
      send(test_pid, {:published, topic, event, payload})
      :ok
    end)

    start_supervised!({Tracker, instance_id: "i-test", heartbeat_ms: 60_000})
    :ok
  end

  defp join_own(user_id) do
    stub(Messaging.Auth.TicketStoreMock, :take, fn _id ->
      {:ok, AuthFixtures.ticket_doc(user_id)}
    end)

    {:ok, socket} = connect(MessagingWeb.UserSocket, %{"ticket" => "a-ticket"})
    subscribe_and_join(socket, UserChannel, "user:" <> user_id)
  end

  describe "join" do
    test "CA1: joining registers the connection and replies the status picked and the idle time" do
      assert {:ok, %{"status" => "dnd", "idle_after_ms" => 300_000}, socket} = join_own(@ana)

      conn_id = socket.assigns.conn_id
      assert_receive {:change, @ana, {:connect, ^conn_id, "i-test"}}
    end

    test "if presence fails the channel still opens: DMs do not depend on it" do
      stub(Messaging.Presence.StoreMock, :change, fn _user_id, _change -> {:error, :timeout} end)

      log =
        capture_log(fn ->
          assert {:ok, %{"status" => "online"}, socket} = join_own(@ana)
          refute Map.has_key?(socket.assigns, :conn_id)
        end)

      assert log =~ "presence_track_failed"
    end

    test "CA4: leaving the channel removes the connection" do
      {:ok, _reply, socket} = join_own(@ana)
      conn_id = socket.assigns.conn_id

      Process.unlink(socket.channel_pid)
      leave(socket)

      assert_receive {:change, @ana, {:disconnect, ^conn_id}}
    end
  end

  describe "set_status" do
    test "CA3: picks a status by hand and every own session hears of it" do
      {:ok, _reply, socket} = join_own(@ana)

      ref = push(socket, "set_status", %{"status" => "invisible"})

      assert_reply ref, :ok, %{"status" => "invisible"}
      assert_receive {:change, @ana, {:set_manual, "invisible"}}

      assert_receive {:published, "user:" <> @ana, "own_status_updated",
                      %{"status" => "invisible"}}
    end

    test "only online, idle, dnd and invisible can be picked" do
      {:ok, _reply, socket} = join_own(@ana)

      for bad <- ["offline", "busy", nil, 3] do
        ref = push(socket, "set_status", %{"status" => bad})
        assert_reply ref, :error, %{error: %{code: "INVALID_STATUS"}}
      end
    end

    test "a store failure answers PRESENCE_UNAVAILABLE" do
      {:ok, _reply, socket} = join_own(@ana)
      stub(Messaging.Presence.StoreMock, :change, fn _user_id, _change -> {:error, :timeout} end)

      capture_log(fn ->
        ref = push(socket, "set_status", %{"status" => "dnd"})
        assert_reply ref, :error, %{error: %{code: "PRESENCE_UNAVAILABLE"}}
      end)
    end
  end

  describe "activity" do
    test "CA2: the client reports idle and active for its own connection" do
      {:ok, _reply, socket} = join_own(@ana)
      conn_id = socket.assigns.conn_id

      ref = push(socket, "activity", %{"state" => "idle"})
      assert_reply ref, :ok
      assert_receive {:change, @ana, {:activity, ^conn_id, true}}

      ref = push(socket, "activity", %{"state" => "active"})
      assert_reply ref, :ok
      assert_receive {:change, @ana, {:activity, ^conn_id, false}}
    end

    test "anything but active or idle is rejected" do
      {:ok, _reply, socket} = join_own(@ana)

      ref = push(socket, "activity", %{"state" => "away"})
      assert_reply ref, :error, %{error: %{code: "INVALID_PAYLOAD"}}
    end

    test "a store failure answers PRESENCE_UNAVAILABLE" do
      {:ok, _reply, socket} = join_own(@ana)
      stub(Messaging.Presence.StoreMock, :change, fn _user_id, _change -> {:error, :timeout} end)

      capture_log(fn ->
        ref = push(socket, "activity", %{"state" => "idle"})
        assert_reply ref, :error, %{error: %{code: "PRESENCE_UNAVAILABLE"}}
      end)
    end
  end

  test "an unknown event is rejected instead of crashing the channel" do
    {:ok, _reply, socket} = join_own(@ana)

    ref = push(socket, "something_else", %{})
    assert_reply ref, :error, %{error: %{code: "INVALID_PAYLOAD"}}
  end

  test "a suspended user cannot change their status" do
    {:ok, _reply, socket} = join_own(@ana)
    Messaging.SuspensionHelper.stub_suspended(@ana)

    ref = push(socket, "set_status", %{"status" => "dnd"})
    assert_reply ref, :error, %{error: %{code: "ACCOUNT_SUSPENDED"}}
    refute_received {:change, @ana, {:set_manual, _}}
  end
end
