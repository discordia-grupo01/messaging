defmodule Messaging.Events.BackoffTest do
  use ExUnit.Case, async: true

  alias Messaging.Events.Backoff

  test "next/1 doubles the backoff, capped at the max" do
    assert Backoff.next(1_000) == 2_000
    assert Backoff.next(20_000) == 30_000
    assert Backoff.next(30_000) == 30_000
  end

  test "initial/0 is smaller than the max" do
    assert Backoff.initial() < 30_000
  end
end
