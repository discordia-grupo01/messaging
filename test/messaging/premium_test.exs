defmodule Messaging.PremiumTest do
  use ExUnit.Case, async: true
  import Mox

  alias Messaging.Premium

  setup :verify_on_exit!

  setup do
    {:ok, user: Messaging.UUID.generate()}
  end

  test "premium?/1 answers what the repo has", %{user: user} do
    expect(Messaging.Chat.RepoMock, :premium?, fn ^user -> true end)
    assert {:ok, true} = Premium.premium?(user)

    expect(Messaging.Chat.RepoMock, :premium?, fn ^user -> false end)
    assert {:ok, false} = Premium.premium?(user)
  end

  test "premium?/1 passes on a read failure", %{user: user} do
    expect(Messaging.Chat.RepoMock, :premium?, fn ^user -> {:error, :not_connected} end)
    assert {:error, :not_connected} = Premium.premium?(user)
  end

  test "apply_event/3 stores the event in the repo", %{user: user} do
    expect(Messaging.Chat.RepoMock, :apply_premium, fn ^user, true, 2 -> {:ok, :applied} end)
    assert {:ok, :applied} = Premium.apply_event(user, true, 2)
  end
end
