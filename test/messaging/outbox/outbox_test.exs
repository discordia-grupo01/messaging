defmodule Messaging.OutboxTest do
  use ExUnit.Case, async: false
  import Mox

  alias Messaging.Outbox
  alias Messaging.Outbox.Poller

  setup :verify_on_exit!

  defp start_poller(opts) do
    pid = start_supervised!({Poller, opts})
    Mox.allow(Messaging.Outbox.StoreMock, self(), pid)
    pid
  end

  @entry %{event: "new_message", topic: "channel:c", payload: %{"id" => "m"}, message_id: "m"}

  test "nothing to enqueue is nothing to do" do
    assert :ok = Outbox.enqueue([])
  end

  test "every entry gets its own id and all of them go to the store in one call" do
    expect(Messaging.Outbox.StoreMock, :insert, fn rows ->
      assert [%{id: first}, %{id: second}] = rows
      assert first != second
      assert Enum.map(rows, & &1.event) == ["new_message", "new_dm"]
      :ok
    end)

    assert :ok = Outbox.enqueue([@entry, %{@entry | event: "new_dm"}])
  end

  test "the store failing is returned, so the caller does not go on" do
    expect(Messaging.Outbox.StoreMock, :insert, fn _rows -> {:error, :timeout} end)

    assert {:error, :timeout} = Outbox.enqueue([@entry])
  end

  test "an already enqueued creation event is returned as a duplicate" do
    expect(Messaging.Outbox.StoreMock, :insert, fn _rows -> :duplicate end)

    assert :duplicate = Outbox.enqueue([@entry])
  end

  test "the poller is woken up as soon as something is recorded" do
    test_pid = self()
    stub(Messaging.Outbox.StoreMock, :insert, fn _rows -> :ok end)

    stub(Messaging.Outbox.StoreMock, :process_pending, fn _limit, _handler ->
      send(test_pid, :polled)
      {:ok, 0}
    end)

    start_poller(interval_ms: 60_000)
    refute_receive :polled, 100

    assert :ok = Outbox.enqueue([@entry])
    assert_receive :polled, 1_000
  end
end
