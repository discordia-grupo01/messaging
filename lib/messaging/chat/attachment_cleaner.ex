defmodule Messaging.Chat.AttachmentCleaner do
  use GenServer

  require Logger

  alias Messaging.Chat.{Attachment, Repo}
  alias Messaging.Log
  alias Messaging.Storage

  @default_interval_ms 10 * 60 * 1000
  @batch 100

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec trigger() :: :ok
  def trigger do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> send(pid, :sweep)
    end

    :ok
  end

  @spec sweep() :: {:ok, non_neg_integer()} | {:error, term()}
  def sweep do
    recover_files_of_deleted_messages()
    sweep(0)
  end

  # Deleting a message marks its files only if the database answers at that
  # moment; this catches the ones it could not mark, on any later sweep.
  defp recover_files_of_deleted_messages do
    at = DateTime.utc_now() |> DateTime.truncate(:millisecond)

    case Repo.impl().orphan_deleted_message_attachments(at, @batch) do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        Logger.info("attachments_recovered", count: count)

      {:error, reason} ->
        Logger.warning("attachments_recover_failed", reason: Log.reason(reason))
    end
  end

  defp sweep(total) do
    pending_before = DateTime.add(DateTime.utc_now(), -Attachment.pending_ttl_seconds(), :second)

    case Repo.impl().list_cleanable_attachments(pending_before, @batch) do
      {:ok, []} -> {:ok, total}
      {:ok, docs} -> remove(docs, total)
      {:error, _reason} = error -> error
    end
  end

  defp remove(docs, total) do
    with :ok <- Storage.delete(Enum.map(docs, & &1["path"])),
         :ok <- Repo.impl().delete_attachments(Enum.map(docs, & &1["_id"])) do
      total = total + length(docs)
      if length(docs) == @batch, do: sweep(total), else: {:ok, total}
    end
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    {:ok, schedule(%{interval: interval, timer: nil})}
  end

  @impl true
  def handle_info(:sweep, state) do
    case sweep() do
      {:ok, 0} -> :ok
      {:ok, count} -> Logger.info("attachments_cleaned", count: count)
      {:error, reason} -> Logger.warning("attachments_clean_failed", reason: Log.reason(reason))
    end

    {:noreply, schedule(state)}
  end

  defp schedule(%{interval: interval, timer: timer} = state) do
    if timer, do: Process.cancel_timer(timer)
    %{state | timer: Process.send_after(self(), :sweep, interval)}
  end
end
