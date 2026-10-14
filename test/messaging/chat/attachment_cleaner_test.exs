defmodule Messaging.Chat.AttachmentCleanerTest do
  use ExUnit.Case, async: false
  import Mox

  alias Messaging.Chat.AttachmentCleaner

  setup :verify_on_exit!

  defp doc(n), do: %{"_id" => "att-#{n}", "path" => "chan-1/att-#{n}.png"}

  test "removes the files from storage and then their records" do
    expect(Messaging.Chat.RepoMock, :list_cleanable_attachments, fn %DateTime{} = before, 100 ->
      assert DateTime.diff(DateTime.utc_now(), before) in 86_399..86_401
      {:ok, [doc(1), doc(2)]}
    end)

    expect(Messaging.StorageMock, :delete, fn ["chan-1/att-1.png", "chan-1/att-2.png"] -> :ok end)
    expect(Messaging.Chat.RepoMock, :delete_attachments, fn ["att-1", "att-2"] -> :ok end)

    assert {:ok, 2} = AttachmentCleaner.sweep()
  end

  test "does nothing, and does not call storage, when there is nothing to clean" do
    expect(Messaging.Chat.RepoMock, :list_cleanable_attachments, fn _before, _limit ->
      {:ok, []}
    end)

    assert {:ok, 0} = AttachmentCleaner.sweep()
  end

  test "keeps going while batches come back full" do
    full = for n <- 1..100, do: doc(n)

    expect(Messaging.Chat.RepoMock, :list_cleanable_attachments, 2, fn _before, _limit ->
      case Process.get(:round, 0) do
        0 ->
          Process.put(:round, 1)
          {:ok, full}

        _ ->
          {:ok, [doc(101)]}
      end
    end)

    expect(Messaging.StorageMock, :delete, 2, fn _paths -> :ok end)
    expect(Messaging.Chat.RepoMock, :delete_attachments, 2, fn _ids -> :ok end)

    assert {:ok, 101} = AttachmentCleaner.sweep()
  end

  test "if storage fails the records stay, so the next sweep tries again" do
    expect(Messaging.Chat.RepoMock, :list_cleanable_attachments, fn _b, _l -> {:ok, [doc(1)]} end)
    expect(Messaging.StorageMock, :delete, fn _paths -> {:error, {:unexpected_status, 500}} end)

    assert {:error, {:unexpected_status, 500}} = AttachmentCleaner.sweep()
  end

  describe "as a process" do
    setup :set_mox_global

    test "sweeps by itself on its interval and when asked" do
      test_pid = self()

      stub(Messaging.Chat.RepoMock, :list_cleanable_attachments, fn _before, _limit ->
        send(test_pid, :listed)
        {:ok, []}
      end)

      start_supervised!({AttachmentCleaner, interval_ms: 40})

      assert_receive :listed, 500
      assert_receive :listed, 500

      assert :ok = AttachmentCleaner.trigger()
      assert_receive :listed, 500
    end

    test "a failing sweep does not stop it" do
      test_pid = self()

      stub(Messaging.Chat.RepoMock, :list_cleanable_attachments, fn _before, _limit ->
        send(test_pid, :listed)
        {:error, :timeout}
      end)

      pid = start_supervised!({AttachmentCleaner, interval_ms: 40})

      assert_receive :listed, 500
      assert_receive :listed, 500
      assert Process.alive?(pid)
    end
  end

  test "trigger/0 is harmless when the cleaner is not running" do
    assert :ok = AttachmentCleaner.trigger()
  end
end
