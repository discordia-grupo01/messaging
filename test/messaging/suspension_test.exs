defmodule Messaging.SuspensionTest do
  use ExUnit.Case, async: false
  import Mox

  alias Messaging.Suspension

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    previous = Application.get_env(:messaging, :suspension_cache_ttl_ms)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:messaging, :suspension_cache_ttl_ms, previous),
        else: Application.delete_env(:messaging, :suspension_cache_ttl_ms)
    end)

    {:ok, user: Messaging.UUID.generate()}
  end

  describe "suspended?/1" do
    test "asks the repo once and answers the next calls from the cache", %{user: user} do
      expect(Messaging.Chat.RepoMock, :suspended?, 1, fn ^user -> true end)

      assert {:ok, true} = Suspension.suspended?(user)
      assert {:ok, true} = Suspension.suspended?(user)
    end

    test "an unknown user is not suspended", %{user: user} do
      expect(Messaging.Chat.RepoMock, :suspended?, fn ^user -> false end)

      assert {:ok, false} = Suspension.suspended?(user)
    end

    test "asks the repo again once the cache entry expired", %{user: user} do
      Application.put_env(:messaging, :suspension_cache_ttl_ms, 10)
      expect(Messaging.Chat.RepoMock, :suspended?, 2, fn ^user -> true end)

      assert {:ok, true} = Suspension.suspended?(user)
      Process.sleep(30)
      assert {:ok, true} = Suspension.suspended?(user)
    end

    test "a repo failure is returned and not cached", %{user: user} do
      expect(Messaging.Chat.RepoMock, :suspended?, fn ^user -> {:error, :timeout} end)
      expect(Messaging.Chat.RepoMock, :suspended?, fn ^user -> false end)

      assert {:error, :timeout} = Suspension.suspended?(user)
      assert {:ok, false} = Suspension.suspended?(user)
    end

    test "users are cached independently", %{user: user} do
      other = Messaging.UUID.generate()
      expect(Messaging.Chat.RepoMock, :suspended?, fn ^user -> true end)
      expect(Messaging.Chat.RepoMock, :suspended?, fn ^other -> false end)

      assert {:ok, true} = Suspension.suspended?(user)
      assert {:ok, false} = Suspension.suspended?(other)
    end
  end

  describe "apply_event/3" do
    test "stores the event and drops the cached answer so the change is seen right away",
         %{user: user} do
      expect(Messaging.Chat.RepoMock, :suspended?, fn ^user -> false end)
      assert {:ok, false} = Suspension.suspended?(user)

      expect(Messaging.Chat.RepoMock, :apply_suspension, fn ^user, true, 5 -> {:ok, :applied} end)
      expect(Messaging.Chat.RepoMock, :suspended?, fn ^user -> true end)

      assert {:ok, :applied} = Suspension.apply_event(user, true, 5)
      assert {:ok, true} = Suspension.suspended?(user)
    end

    test "a stale event is reported as such", %{user: user} do
      expect(Messaging.Chat.RepoMock, :apply_suspension, fn ^user, false, 1 -> {:ok, :stale} end)

      assert {:ok, :stale} = Suspension.apply_event(user, false, 1)
    end

    test "a repo failure is returned", %{user: user} do
      expect(Messaging.Chat.RepoMock, :apply_suspension, fn ^user, true, 1 ->
        {:error, :not_connected}
      end)

      assert {:error, :not_connected} = Suspension.apply_event(user, true, 1)
    end
  end

  test "init/0 can run again without failing" do
    assert :ok = Suspension.init()
    assert :ok = Suspension.init()
  end
end
