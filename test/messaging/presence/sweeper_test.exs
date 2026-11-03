defmodule Messaging.Presence.SweeperTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Mox

  alias Messaging.Presence.Sweeper

  setup :verify_on_exit!

  @ana "11111111-1111-4111-8111-111111111111"
  @beto "22222222-2222-4222-8222-222222222222"
  @now ~U[2026-10-23 12:00:00Z]

  setup do
    # Nobody hears about the changes in these tests: no servers, no DMs.
    stub(Messaging.Presence.StoreMock, :member_server_ids, fn _ -> {:ok, []} end)
    stub(Messaging.Presence.StoreMock, :dm_partner_ids, fn _, _ -> {:ok, []} end)
    stub(Messaging.Outbox.StoreMock, :insert, fn _rows -> :ok end)
    :ok
  end

  defp online_on(instance_id),
    do: %{
      "manual" => "online",
      "connections" => [%{"id" => "c", "instance" => instance_id, "idle" => false}],
      "version" => 1
    }

  test "CA4: drops the connections of an instance that stopped beating, then its record" do
    expect(Messaging.Presence.StoreMock, :stale_instances, fn cutoff ->
      assert cutoff == DateTime.add(@now, -30_000, :millisecond)
      {:ok, ["dead"]}
    end)

    expect(Messaging.Presence.StoreMock, :user_ids_on_instance, fn "dead" ->
      {:ok, [@ana, @beto]}
    end)

    expect(Messaging.Presence.StoreMock, :change, 2, fn _user_id, {:drop_instance, "dead"} ->
      {:ok, {:changed, online_on("dead")}}
    end)

    expect(Messaging.Presence.StoreMock, :delete_instance, fn "dead" -> :ok end)

    assert {:ok, 1} = Sweeper.sweep(@now)
  end

  test "nothing stale, nothing to do" do
    expect(Messaging.Presence.StoreMock, :stale_instances, fn _cutoff -> {:ok, []} end)

    assert {:ok, 0} = Sweeper.sweep(@now)
  end

  test "if a connection cannot be dropped the record stays, so the next sweep retries" do
    expect(Messaging.Presence.StoreMock, :stale_instances, fn _ -> {:ok, ["dead"]} end)
    expect(Messaging.Presence.StoreMock, :user_ids_on_instance, fn "dead" -> {:ok, [@ana]} end)

    expect(Messaging.Presence.StoreMock, :change, fn @ana, {:drop_instance, "dead"} ->
      {:error, :timeout}
    end)

    log = capture_log(fn -> assert {:ok, 0} = Sweeper.sweep(@now) end)
    assert log =~ "presence_sweep_failed"
  end

  test "a failure listing the stale instances is returned" do
    expect(Messaging.Presence.StoreMock, :stale_instances, fn _ -> {:error, :timeout} end)

    assert {:error, :timeout} = Sweeper.sweep(@now)
  end

  describe "the periodic sweep" do
    setup :set_mox_global

    test "runs on every interval and survives a failure" do
      test_pid = self()

      stub(Messaging.Presence.StoreMock, :stale_instances, fn _cutoff ->
        send(test_pid, :swept)
        {:error, :timeout}
      end)

      log =
        capture_log(fn ->
          start_supervised!({Sweeper, interval_ms: 10})
          assert_receive :swept
          assert_receive :swept
        end)

      assert log =~ "presence_sweep_failed"
    end
  end
end
