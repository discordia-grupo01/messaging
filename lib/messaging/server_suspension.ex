defmodule Messaging.ServerSuspension do
  @moduledoc """
  Whether a server is suspended by the platform staff. The state lives in Mongo
  (`suspended_servers`, fed by `admin.server_suspended` / `admin.server_reactivated`)
  so it survives restarts and is shared by every instance; a short ETS cache keeps
  the check out of the hot path. A server with no document is active.

  The messages of a suspended server are kept: this only decides whether anyone
  may read or write them.
  """

  alias Messaging.Chat.Repo
  alias Messaging.Log

  require Logger

  @table :messaging_server_suspension_cache
  @default_ttl_ms 5_000

  @doc "Creates the cache table. Idempotent; the application calls it on start."
  @spec init() :: :ok
  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end

  @spec suspended?(String.t()) :: {:ok, boolean()} | {:error, term()}
  def suspended?(server_id) when is_binary(server_id) do
    case cached(server_id) do
      {:ok, _suspended} = hit -> hit
      :miss -> load(server_id)
    end
  end

  @doc """
  `:ok` when the server may be used. A suspended server gives `:server_suspended`;
  if the state cannot be read the answer is `:suspension_unavailable` (fail closed:
  an action is never allowed on a guess).
  """
  @spec ensure_active(String.t()) ::
          :ok | {:error, :server_suspended | :suspension_unavailable}
  def ensure_active(server_id) do
    case suspended?(server_id) do
      {:ok, false} ->
        :ok

      {:ok, true} ->
        {:error, :server_suspended}

      {:error, reason} ->
        Logger.error("server_suspension_check_failed",
          server_id: server_id,
          reason: Log.reason(reason)
        )

        {:error, :suspension_unavailable}
    end
  end

  @doc """
  Stores a suspension event. Returns `{:ok, :stale}` when the stored version is
  already the same or newer. The cache entry is dropped so this instance sees the
  change right away.
  """
  @spec apply_event(String.t(), boolean(), integer()) ::
          {:ok, :applied | :stale} | {:error, term()}
  def apply_event(server_id, suspended, version) when is_boolean(suspended) do
    result = Repo.impl().apply_server_suspension(server_id, suspended, version)
    invalidate(server_id)
    result
  end

  @spec invalidate(String.t()) :: :ok
  def invalidate(server_id) do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table, server_id)
    :ok
  end

  defp load(server_id) do
    case Repo.impl().server_suspended?(server_id) do
      suspended when is_boolean(suspended) ->
        put(server_id, suspended)
        {:ok, suspended}

      {:error, _reason} = error ->
        error
    end
  end

  defp cached(server_id) do
    with true <- :ets.whereis(@table) != :undefined,
         [{^server_id, suspended, expires_at}] <- :ets.lookup(@table, server_id),
         true <- now() < expires_at do
      {:ok, suspended}
    else
      _miss -> :miss
    end
  end

  defp put(server_id, suspended) do
    if :ets.whereis(@table) != :undefined,
      do: :ets.insert(@table, {server_id, suspended, now() + ttl_ms()})

    :ok
  end

  defp ttl_ms,
    do: Application.get_env(:messaging, :suspension_cache_ttl_ms, @default_ttl_ms)

  defp now, do: System.monotonic_time(:millisecond)
end
