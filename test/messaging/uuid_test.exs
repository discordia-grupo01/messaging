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
end
