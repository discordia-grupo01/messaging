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

  test "v5/2 matches the RFC 4122 reference value for the DNS namespace" do
    assert UUID.v5("6ba7b810-9dad-11d1-80b4-00c04fd430c8", "python.org") ==
             "886313e1-3b8a-5372-9b90-0c9aee199e5d"
  end

  test "v5/2 is deterministic, versioned 5 and sensitive to the name" do
    namespace = "d15c0d1a-5e0f-4f6e-9a3c-6d6d5f0e7b21"

    assert UUID.v5(namespace, "dm:aaa:bbb") == "d8e4a0ff-9837-5fa9-9610-89f24542fb40"
    assert UUID.v5(namespace, "dm:aaa:bbb") == UUID.v5(namespace, "dm:aaa:bbb")
    refute UUID.v5(namespace, "dm:aaa:bbb") == UUID.v5(namespace, "dm:aaa:bbc")

    assert UUID.v5(namespace, "x") =~
             ~r/^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
  end
end
