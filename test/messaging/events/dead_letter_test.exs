defmodule Messaging.Events.DeadLetterTest do
  use ExUnit.Case, async: false

  alias Messaging.Events.DeadLetter

  setup do
    on_exit(fn ->
      Application.delete_env(:messaging, :event_retry_delay_ms)
      Application.delete_env(:messaging, :event_max_attempts)
    end)
  end

  describe "delay/2" do
    test "doubles on every attempt until it reaches the cap" do
      delays = for attempt <- 1..7, do: DeadLetter.delay(attempt, 0.5)

      assert delays == [1_000, 2_000, 4_000, 8_000, 16_000, 30_000, 30_000]
    end

    test "the jitter moves the delay at most 20% either way" do
      assert DeadLetter.delay(3, 0) == 3_200
      assert DeadLetter.delay(3, 1) == 4_800
    end

    test "starts from the configured base" do
      Application.put_env(:messaging, :event_retry_delay_ms, 50)

      assert DeadLetter.delay(1, 0.5) == 50
      assert DeadLetter.delay(3, 0.5) == 200
    end

    test "a huge attempt number does not overflow" do
      assert DeadLetter.delay(10_000, 0.5) == 30_000
    end
  end

  describe "max_attempts/0" do
    test "is 5 by default" do
      assert DeadLetter.max_attempts() == 5
    end

    test "can be configured" do
      Application.put_env(:messaging, :event_max_attempts, 2)

      assert DeadLetter.max_attempts() == 2
    end
  end

  describe "identity/2" do
    test "is the same for the same routing key and body" do
      assert DeadLetter.identity("a.b", "{}") == DeadLetter.identity("a.b", "{}")
    end

    test "changes with the routing key or the body" do
      refute DeadLetter.identity("a.b", "{}") == DeadLetter.identity("a.c", "{}")
      refute DeadLetter.identity("a.b", "{}") == DeadLetter.identity("a.b", "{\"x\":1}")
    end
  end

  test "the dead letter queue of a queue is named after it and the exchange is shared" do
    assert DeadLetter.queue_for("messaging.admin_events") == "messaging.admin_events.dlq"
    assert DeadLetter.exchange() == "discordia.dlx"
  end
end
