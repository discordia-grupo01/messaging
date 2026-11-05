defmodule Messaging.ServerSuspensionTest do
  use ExUnit.Case, async: false
  import Mox

  alias Messaging.ServerSuspension

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    previous = Application.get_env(:messaging, :suspension_cache_ttl_ms)
    Application.put_env(:messaging, :suspension_cache_ttl_ms, 60_000)

    on_exit(fn ->
      Application.put_env(:messaging, :suspension_cache_ttl_ms, previous)
    end)

    {:ok, server: Messaging.UUID.generate()}
  end

  describe "suspended?/1" do
    test "asks the repo once and answers the next calls from the cache", %{server: server} do
      expect(Messaging.Chat.RepoMock, :server_suspended?, 1, fn ^server -> true end)

      assert {:ok, true} = ServerSuspension.suspended?(server)
      assert {:ok, true} = ServerSuspension.suspended?(server)
    end

    test "a server nobody suspended is active", %{server: server} do
      expect(Messaging.Chat.RepoMock, :server_suspended?, fn ^server -> false end)

      assert {:ok, false} = ServerSuspension.suspended?(server)
    end

    test "asks the repo again once the cache entry expired", %{server: server} do
      Application.put_env(:messaging, :suspension_cache_ttl_ms, 10)
      expect(Messaging.Chat.RepoMock, :server_suspended?, 2, fn ^server -> true end)

      assert {:ok, true} = ServerSuspension.suspended?(server)
      Process.sleep(30)
      assert {:ok, true} = ServerSuspension.suspended?(server)
    end

    test "a repo failure is returned and not cached", %{server: server} do
      expect(Messaging.Chat.RepoMock, :server_suspended?, fn ^server -> {:error, :timeout} end)
      expect(Messaging.Chat.RepoMock, :server_suspended?, fn ^server -> false end)

      assert {:error, :timeout} = ServerSuspension.suspended?(server)
      assert {:ok, false} = ServerSuspension.suspended?(server)
    end

    test "servers are cached independently", %{server: server} do
      other = Messaging.UUID.generate()
      expect(Messaging.Chat.RepoMock, :server_suspended?, fn ^server -> true end)
      expect(Messaging.Chat.RepoMock, :server_suspended?, fn ^other -> false end)

      assert {:ok, true} = ServerSuspension.suspended?(server)
      assert {:ok, false} = ServerSuspension.suspended?(other)
    end
  end

  describe "ensure_active/1" do
    test "lets an active server through", %{server: server} do
      expect(Messaging.Chat.RepoMock, :server_suspended?, fn ^server -> false end)

      assert :ok = ServerSuspension.ensure_active(server)
    end

    test "refuses a suspended server", %{server: server} do
      expect(Messaging.Chat.RepoMock, :server_suspended?, fn ^server -> true end)

      assert {:error, :server_suspended} = ServerSuspension.ensure_active(server)
    end

    test "fails closed and logs when the state cannot be read", %{server: server} do
      expect(Messaging.Chat.RepoMock, :server_suspended?, fn ^server -> {:error, :timeout} end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :suspension_unavailable} = ServerSuspension.ensure_active(server)
        end)

      assert log =~ "server_suspension_check_failed"
    end
  end

  describe "apply_event/3" do
    test "stores the event and drops the cached answer so the change is seen right away",
         %{server: server} do
      expect(Messaging.Chat.RepoMock, :server_suspended?, fn ^server -> false end)
      assert {:ok, false} = ServerSuspension.suspended?(server)

      expect(Messaging.Chat.RepoMock, :apply_server_suspension, fn ^server, true, 5 ->
        {:ok, :applied}
      end)

      expect(Messaging.Chat.RepoMock, :server_suspended?, fn ^server -> true end)

      assert {:ok, :applied} = ServerSuspension.apply_event(server, true, 5)
      assert {:ok, true} = ServerSuspension.suspended?(server)
    end

    test "a stale event is reported as such", %{server: server} do
      expect(Messaging.Chat.RepoMock, :apply_server_suspension, fn ^server, false, 1 ->
        {:ok, :stale}
      end)

      assert {:ok, :stale} = ServerSuspension.apply_event(server, false, 1)
    end

    test "a repo failure is returned", %{server: server} do
      expect(Messaging.Chat.RepoMock, :apply_server_suspension, fn ^server, true, 1 ->
        {:error, :not_connected}
      end)

      assert {:error, :not_connected} = ServerSuspension.apply_event(server, true, 1)
    end
  end

  test "init/0 can run again without failing" do
    assert :ok = ServerSuspension.init()
    assert :ok = ServerSuspension.init()
  end
end
