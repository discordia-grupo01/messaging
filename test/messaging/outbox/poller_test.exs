defmodule Messaging.Outbox.PollerTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Mox

  alias Messaging.Outbox.Poller

  setup :verify_on_exit!

  defp start_poller(opts) do
    pid = start_supervised!({Poller, opts})
    Mox.allow(Messaging.Outbox.StoreMock, self(), pid)
    pid
  end

  test "run_once/0 hands the pending rows to the dispatcher in batches of 50" do
    expect(Messaging.Outbox.StoreMock, :process_pending, fn 50, handler ->
      assert is_function(handler, 1)
      assert [] = handler.([])
      {:ok, 3}
    end)

    assert {:ok, 3} = Poller.run_once()
  end

  test "it polls on its own interval" do
    test_pid = self()

    stub(Messaging.Outbox.StoreMock, :process_pending, fn _limit, _handler ->
      send(test_pid, :polled)
      {:ok, 0}
    end)

    start_poller(interval_ms: 30)

    assert_receive :polled, 500
    assert_receive :polled, 500
  end

  test "a poll that published something is followed right away by another one" do
    test_pid = self()
    counter = :counters.new(1, [])

    stub(Messaging.Outbox.StoreMock, :process_pending, fn _limit, _handler ->
      :counters.add(counter, 1, 1)
      send(test_pid, {:polled, :counters.get(counter, 1)})
      if :counters.get(counter, 1) < 3, do: {:ok, 1}, else: {:ok, 0}
    end)

    start_poller(interval_ms: 60_000)
    Poller.kick()

    assert_receive {:polled, 1}, 500
    assert_receive {:polled, 2}, 500
    assert_receive {:polled, 3}, 500
  end

  test "a poll that published nothing waits for the interval" do
    test_pid = self()

    stub(Messaging.Outbox.StoreMock, :process_pending, fn _limit, _handler ->
      send(test_pid, :polled)
      {:ok, 0}
    end)

    start_poller(interval_ms: 60_000)
    Poller.kick()

    assert_receive :polled, 500
    refute_receive :polled, 200
  end

  test "several kicks in a row do not pile up into several polls" do
    test_pid = self()

    stub(Messaging.Outbox.StoreMock, :process_pending, fn _limit, _handler ->
      send(test_pid, :polled)
      {:ok, 0}
    end)

    pid = start_poller(interval_ms: 60_000)
    :sys.suspend(pid)
    for _ <- 1..20, do: Poller.kick()
    :sys.resume(pid)

    assert_receive :polled, 500
    refute_receive :polled, 200
  end

  test "a failing poll is logged and the poller keeps going" do
    test_pid = self()

    stub(Messaging.Outbox.StoreMock, :process_pending, fn _limit, _handler ->
      send(test_pid, :polled)
      {:error, :timeout}
    end)

    log =
      capture_log(fn ->
        pid = start_poller(interval_ms: 30)

        assert_receive :polled, 500
        assert_receive :polled, 500
        assert Process.alive?(pid)
      end)

    assert log =~ "outbox_poll_failed"
  end

  test "kick/0 is harmless when the poller is not running" do
    assert :ok = Poller.kick()
  end
end
