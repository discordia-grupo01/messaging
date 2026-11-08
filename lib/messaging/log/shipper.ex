defmodule Messaging.Log.Shipper do
  use GenServer, shutdown: 8_000

  alias Messaging.Log.Httpc
  alias Messaging.Log.ShipperHandler

  require Logger

  @defaults [
    max_batch: 200,
    max_queue: 5_000,
    flush_interval_ms: 5_000,
    base_backoff_ms: 1_000,
    max_backoff_ms: 60_000,
    request_timeout_ms: 10_000,
    drain_timeout_ms: 3_000
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec enqueue(map()) :: :ok
  def enqueue(entry), do: GenServer.cast(__MODULE__, {:entry, entry})

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    config = Keyword.merge(@defaults, opts)

    state = %{
      config: config,
      queue: :queue.new(),
      size: 0,
      inflight: nil,
      failures: 0,
      dropped: 0,
      timer: nil
    }

    case ShipperHandler.attach() do
      :ok -> {:ok, schedule(state, config[:flush_interval_ms])}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_cast({:entry, entry}, state) do
    state = push(state, entry)

    if ready_for_batch?(state),
      do: {:noreply, send_batch(state)},
      else: {:noreply, state}
  end

  @impl true
  def handle_info(:flush, %{inflight: nil, size: 0} = state),
    do: {:noreply, schedule(state, state.config[:flush_interval_ms])}

  def handle_info(:flush, %{inflight: nil} = state), do: {:noreply, send_batch(state)}
  def handle_info(:flush, state), do: {:noreply, state}

  def handle_info({:result, pid, result}, %{inflight: {pid, monitor, batch}} = state) do
    Process.demonitor(monitor, [:flush])
    {:noreply, finish(%{state | inflight: nil}, batch, result)}
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, _reason},
        %{inflight: {_, monitor, batch}} = state
      ),
      do: {:noreply, finish(%{state | inflight: nil}, batch, {:retry, :sender_crashed})}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    ShipperHandler.detach()
    drain(state)
  end

  defp push(%{size: size, config: config} = state, entry) do
    if size >= config[:max_queue] do
      {_dropped, queue} = :queue.out(state.queue)
      %{state | queue: :queue.in(entry, queue), dropped: state.dropped + 1}
    else
      %{state | queue: :queue.in(entry, state.queue), size: size + 1}
    end
  end

  defp ready_for_batch?(%{inflight: nil, failures: 0, size: size, config: config}),
    do: size >= config[:max_batch]

  defp ready_for_batch?(_state), do: false

  defp send_batch(%{queue: queue, size: size, config: config} = state) do
    count = min(size, config[:max_batch])
    {taken, rest} = :queue.split(count, queue)
    batch = :queue.to_list(taken)
    parent = self()
    request = request(config)

    {pid, monitor} =
      spawn_monitor(fn -> send(parent, {:result, self(), post(request, batch)}) end)

    state = cancel_timer(state)
    %{state | queue: rest, size: size - count, inflight: {pid, monitor, batch}}
  end

  defp finish(state, _batch, :ok) do
    state = state |> recover() |> Map.put(:failures, 0)
    delay = if ready_for_batch?(state), do: 0, else: state.config[:flush_interval_ms]
    schedule(state, delay)
  end

  defp finish(state, batch, {:retry, reason}) do
    failures = state.failures + 1
    if failures == 1, do: ship_log(:warning, "log_shipping_failed", reason: reason)

    state
    |> requeue(batch)
    |> Map.put(:failures, failures)
    |> schedule(backoff(failures, state.config))
  end

  defp finish(state, batch, {:drop, reason}) do
    ship_log(:warning, "log_batch_discarded", reason: reason, count: length(batch))
    schedule(%{state | failures: 0}, state.config[:flush_interval_ms])
  end

  defp recover(%{failures: failures} = state) when failures > 0 do
    ship_log(:info, "log_shipping_recovered", count: state.dropped)
    %{state | dropped: 0}
  end

  defp recover(%{dropped: dropped} = state) when dropped > 0 do
    ship_log(:warning, "log_entries_dropped", count: dropped)
    %{state | dropped: 0}
  end

  defp recover(state), do: state

  defp requeue(state, batch) do
    queue = Enum.reduce(Enum.reverse(batch), state.queue, &:queue.in_r/2)
    overflow = max(state.size + length(batch) - state.config[:max_queue], 0)
    {_discarded, queue} = :queue.split(overflow, queue)

    %{
      state
      | queue: queue,
        size: state.size + length(batch) - overflow,
        dropped: state.dropped + overflow
    }
  end

  defp backoff(failures, config) do
    min(config[:base_backoff_ms] * Integer.pow(2, min(failures - 1, 16)), config[:max_backoff_ms])
  end

  defp schedule(state, delay) do
    state = cancel_timer(state)
    %{state | timer: Process.send_after(self(), :flush, delay)}
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end

  defp drain(%{size: 0}), do: :ok

  defp drain(%{config: config} = state) do
    deadline = System.monotonic_time(:millisecond) + config[:drain_timeout_ms]
    drain(:queue.to_list(state.queue), request(config), deadline, config[:max_batch])
  end

  defp drain([], _request, _deadline, _max_batch), do: :ok

  defp drain(entries, request, deadline, max_batch) do
    if System.monotonic_time(:millisecond) >= deadline do
      :ok
    else
      {batch, rest} = Enum.split(entries, max_batch)

      case post(request, batch) do
        :ok -> drain(rest, request, deadline, max_batch)
        _failure -> :ok
      end
    end
  end

  defp request(config) do
    %{
      url: Keyword.fetch!(config, :url),
      api_key: Keyword.fetch!(config, :api_key),
      service: Keyword.get(config, :service, "messaging"),
      timeout_ms: config[:request_timeout_ms]
    }
  end

  defp post(request, batch) do
    payload = [
      %{
        common: %{attributes: %{"service.name": request.service, "entity.name": request.service}},
        logs: batch
      }
    ]

    headers = [
      {"content-type", "application/json"},
      {"content-encoding", "gzip"},
      {"api-key", request.api_key}
    ]

    body = payload |> Jason.encode!() |> :zlib.gzip()

    case Httpc.post(request.url, headers, body, request.timeout_ms) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} when status in [408, 429] or status >= 500 -> {:retry, status}
      {:ok, %{status: status}} -> {:drop, status}
      {:error, reason} -> {:retry, reason}
    end
  end

  defp ship_log(level, message, metadata),
    do: Logger.log(level, message, [{:domain, [:log_shipper]} | metadata])
end
