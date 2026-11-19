defmodule Messaging.CircuitBreaker do
  use GenServer

  require Logger

  @table __MODULE__
  @default_threshold 5
  @default_open_ms 30_000

  @type name :: term()
  @type state :: :closed | :open | :half_open
  @type option ::
          {:threshold, pos_integer()}
          | {:open_ms, pos_integer()}
          | {:failure?, (term() -> boolean())}
          | {:now_ms, (-> integer())}

  def start_link(_options), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  @spec call(name(), (-> result), [option()]) :: result | {:error, :circuit_open}
        when result: term()
  def call(name, fun, options \\ []) when is_function(fun, 0) do
    case acquire(name, options) do
      {:ok, mode} -> run(name, mode, fun, options)
      :open -> {:error, :circuit_open}
    end
  end

  @spec state(name(), [option()]) :: state()
  def state(name, options \\ []) do
    case :ets.lookup(@table, name) do
      [{^name, :open, _failures, opened_at}] ->
        if now(options) - opened_at >= open_ms(options), do: :half_open, else: :open

      [{^name, state, _failures, _since}] ->
        state

      [] ->
        :closed
    end
  end

  @spec reset(name()) :: :ok
  def reset(name) do
    :ets.delete(@table, name)
    :ok
  end

  @spec server_failure?(term()) :: boolean()
  def server_failure?({:error, _reason}), do: true
  def server_failure?({:ok, %{status: status}}), do: status >= 500 or status == 429
  def server_failure?(_result), do: false

  defp run(name, mode, fun, options) do
    result =
      try do
        fun.()
      catch
        kind, reason ->
          record(name, mode, :failure, options)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    failure? = Keyword.get(options, :failure?, &server_failure?/1)
    record(name, mode, if(failure?.(result), do: :failure, else: :success), options)
    result
  end

  defp acquire(name, options) do
    now = now(options)

    case :ets.lookup(@table, name) do
      [] ->
        {:ok, :closed}

      [{^name, :closed, _failures, _opened_at}] ->
        {:ok, :closed}

      [{^name, state, _failures, since}] ->
        if now - since >= open_ms(options), do: probe(name, state, since, now), else: :open
    end
  end

  defp probe(name, state, since, now) do
    match = [{{name, state, :"$1", since}, [], [{{{:const, name}, :half_open, 0, now}}]}]

    if :ets.select_replace(@table, match) == 1 do
      if state == :open, do: log_change(name, :open, :half_open)
      {:ok, :probe}
    else
      :open
    end
  end

  defp record(name, :closed, :success, _options) do
    match = [{{name, :closed, :_, :_}, [], [{{{:const, name}, :closed, 0, 0}}]}]
    :ets.select_replace(@table, match)
    :ok
  end

  defp record(name, :closed, :failure, options) do
    :ets.insert_new(@table, {name, :closed, 0, 0})
    failures = :ets.update_counter(@table, name, {3, 1})
    now = now(options)

    match = [
      {{name, :closed, :"$1", :_}, [{:>=, :"$1", threshold(options)}],
       [{{{:const, name}, :open, 0, now}}]}
    ]

    if failures >= threshold(options) and :ets.select_replace(@table, match) == 1,
      do: log_change(name, :closed, :open)

    :ok
  end

  defp record(name, :probe, :success, _options) do
    :ets.insert(@table, {name, :closed, 0, 0})
    log_change(name, :half_open, :closed)
  end

  defp record(name, :probe, :failure, options) do
    :ets.insert(@table, {name, :open, 0, now(options)})
    log_change(name, :half_open, :open)
  end

  defp log_change(name, from, to),
    do:
      Logger.warning("circuit_breaker_state_changed", breaker: inspect(name), from: from, to: to)

  defp threshold(options), do: Keyword.get(options, :threshold, @default_threshold)
  defp open_ms(options), do: Keyword.get(options, :open_ms, @default_open_ms)

  defp now(options) do
    case Keyword.get(options, :now_ms) do
      nil -> System.monotonic_time(:millisecond)
      fun -> fun.()
    end
  end
end
