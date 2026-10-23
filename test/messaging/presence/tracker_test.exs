defmodule Messaging.Presence.TrackerTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Mox

  alias Messaging.Presence.Tracker

  setup :set_mox_global
  setup :verify_on_exit!

  @ana "11111111-1111-4111-8111-111111111111"
  @tracker :presence_tracker_test

  setup do
    test_pid = self()

    stub(Messaging.Presence.StoreMock, :heartbeat, fn instance_id, %DateTime{} ->
      send(test_pid, {:heartbeat, instance_id})
      :ok
    end)

    stub(Messaging.Presence.StoreMock, :change, fn user_id, change ->
      send(test_pid, {:change, user_id, change})
      {:ok, :unchanged}
    end)

    stub(Messaging.Presence.StoreMock, :delete_instance, fn instance_id ->
      send(test_pid, {:deleted, instance_id})
      :ok
    end)

    :ok
  end

  defp start_tracker(opts \\ []) do
    opts = Keyword.merge([name: @tracker, instance_id: "i-test", heartbeat_ms: 60_000], opts)
    start_supervised!({Tracker, opts})
  end

  defp fake_channel, do: spawn(fn -> Process.sleep(:infinity) end)

  test "writes the heartbeat of the instance when it starts and then on every interval" do
    start_tracker(heartbeat_ms: 20)

    assert_receive {:heartbeat, "i-test"}
    assert_receive {:heartbeat, "i-test"}
    assert_receive {:heartbeat, "i-test"}
  end

  test "a failed heartbeat is logged and the tracker keeps going" do
    stub(Messaging.Presence.StoreMock, :heartbeat, fn _id, _at -> {:error, :timeout} end)

    log =
      capture_log(fn ->
        start_tracker()
        assert "i-test" = Tracker.instance_id(@tracker)
      end)

    assert log =~ "presence_heartbeat_failed"
  end

  test "track/3 registers the connection on this instance and returns its id" do
    start_tracker()
    channel = fake_channel()

    assert {:ok, %{conn_id: conn_id, status: "online"}} = Tracker.track(@tracker, channel, @ana)
    assert_receive {:change, @ana, {:connect, ^conn_id, "i-test"}}
  end

  test "CA4: when the channel process ends the connection is removed" do
    start_tracker()
    channel = fake_channel()
    {:ok, %{conn_id: conn_id}} = Tracker.track(@tracker, channel, @ana)

    Process.exit(channel, :kill)

    assert_receive {:change, @ana, {:disconnect, ^conn_id}}
  end

  test "each tab is its own connection" do
    start_tracker()
    {:ok, %{conn_id: first}} = Tracker.track(@tracker, fake_channel(), @ana)
    {:ok, %{conn_id: second}} = Tracker.track(@tracker, fake_channel(), @ana)

    assert first != second
  end

  test "if the connection cannot be stored, the channel is not watched" do
    stub(Messaging.Presence.StoreMock, :change, fn _user_id, _change -> {:error, :timeout} end)
    start_tracker()
    channel = fake_channel()

    capture_log(fn -> assert {:error, :timeout} = Tracker.track(@tracker, channel, @ana) end)
    Process.exit(channel, :kill)

    refute_receive {:change, _, {:disconnect, _}}, 50
  end

  test "a failed disconnect is retried" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)
    test_pid = self()

    stub(Messaging.Presence.StoreMock, :change, fn
      _user_id, {:connect, _, _} ->
        {:ok, :unchanged}

      _user_id, {:disconnect, _} = change ->
        if Agent.get_and_update(calls, &{&1, &1 + 1}) == 0 do
          {:error, :timeout}
        else
          send(test_pid, {:change, @ana, change})
          {:ok, :unchanged}
        end
    end)

    start_tracker()
    channel = fake_channel()
    {:ok, %{conn_id: conn_id}} = Tracker.track(@tracker, channel, @ana)

    capture_log(fn ->
      Process.exit(channel, :kill)
      assert_receive {:change, @ana, {:disconnect, ^conn_id}}, 2_000
    end)
  end

  test "on shutdown it drops its connections and its instance record" do
    start_tracker()
    {:ok, _} = Tracker.track(@tracker, fake_channel(), @ana)
    {:ok, _} = Tracker.track(@tracker, fake_channel(), @ana)

    stop_supervised!(Tracker)

    assert_receive {:change, @ana, {:drop_instance, "i-test"}}
    refute_receive {:change, @ana, {:drop_instance, "i-test"}}, 50
    assert_receive {:deleted, "i-test"}
  end

  test "a tracker that does not answer is an error, not a crash of the caller" do
    {:ok, stuck} = Agent.start_link(fn -> nil end)
    :sys.suspend(stuck)

    assert {:error, {:tracker_unavailable, _reason}} = Tracker.track(stuck, self(), @ana)
  end

  test "without a tracker running nothing is tracked" do
    assert :untracked = Tracker.track(:no_tracker_here, self(), @ana)
  end
end
