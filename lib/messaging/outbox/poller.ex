defmodule Messaging.Outbox.Poller do
  use GenServer

  require Logger

  alias Messaging.Log
  alias Messaging.Outbox.{Dispatcher, Store}

  @default_interval_ms 1_000
  @batch 50

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec kick() :: :ok
  def kick do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> send(pid, :poll)
    end

    :ok
  end

  @spec run_once() :: {:ok, non_neg_integer()} | {:error, term()}
  def run_once, do: Store.process_pending(@batch, &Dispatcher.handle_batch/1)

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    {:ok, schedule(%{interval: interval, timer: nil})}
  end

  @impl true
  def handle_info(:poll, state) do
    flush_polls()

    case run_once() do
      {:ok, 0} ->
        :ok

      {:ok, _published} ->
        send(self(), :poll)

      {:error, reason} ->
        Logger.warning("outbox_poll_failed", reason: Log.reason(reason))
    end

    {:noreply, schedule(state)}
  end

  defp flush_polls do
    receive do
      :poll -> flush_polls()
    after
      0 -> :ok
    end
  end

  defp schedule(%{interval: interval, timer: timer} = state) do
    if timer, do: Process.cancel_timer(timer)
    %{state | timer: Process.send_after(self(), :poll, interval)}
  end
end
