defmodule Messaging.UUIDTest do
  use ExUnit.Case, async: true

  alias Messaging.UUID

  test "generate/0 returns a well-formed UUIDv4" do
    uuid = UUID.generate()

    assert uuid =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
  end

  test "generate/0 never repeats across calls" do
    uuids = for _ <- 1..1_000, do: UUID.generate()

    assert length(Enum.uniq(uuids)) == 1_000
  end

  test "generate_v7/0 returns a well-formed UUIDv7" do
    uuid = UUID.generate_v7()

    assert uuid =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
  end

  test "generate_v7/0 is strictly increasing, even inside the same millisecond" do
    uuids = for _ <- 1..20_000, do: UUID.generate_v7()

    assert uuids == Enum.sort(uuids)
    assert length(Enum.uniq(uuids)) == 20_000
  end

  test "generate_v7/0 stays unique and ordered per caller under concurrency" do
    results =
      1..8
      |> Task.async_stream(fn _ -> for _ <- 1..2_000, do: UUID.generate_v7() end)
      |> Enum.map(fn {:ok, uuids} -> uuids end)

    assert Enum.all?(results, &(&1 == Enum.sort(&1)))
    assert results |> List.flatten() |> Enum.uniq() |> length() == 16_000
  end

  test "generate_v7/0 carries the current time in its first 48 bits" do
    before_ms = System.os_time(:millisecond)
    uuid = UUID.generate_v7()
    after_ms = System.os_time(:millisecond)

    <<ms::48, _rest::bitstring>> = Base.decode16!(String.replace(uuid, "-", ""), case: :lower)

    assert ms >= before_ms and ms <= after_ms + 1
  end
end
