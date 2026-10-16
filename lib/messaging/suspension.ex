defmodule Messaging.Suspension do
  @moduledoc """
  Whether an account is suspended. The state lives in Mongo (`suspended_users`,
  fed by the `admin.*` events) so it survives restarts and is shared by every
  instance; a short ETS cache keeps the check out of the hot path.
  """

  alias Messaging.Chat.Repo
  alias Messaging.Log

  require Logger

  @table :messaging_suspension_cache
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
  def suspended?(user_id) when is_binary(user_id) do
    case cached(user_id) do
      {:ok, _suspended} = hit -> hit
      :miss -> load(user_id)
    end
  end

  @doc """
  `:ok` when the user may act. A suspended user gets `:account_suspended`; if the
  state cannot be read the answer is `:suspension_unavailable` (fail closed: an
  action is never allowed on a guess).
  """
  @spec ensure_active(String.t()) ::
          :ok | {:error, :account_suspended | :suspension_unavailable}
  def ensure_active(user_id) do
    case suspended?(user_id) do
      {:ok, false} ->
        :ok

      {:ok, true} ->
        {:error, :account_suspended}

      {:error, reason} ->
        Logger.error("suspension_check_failed", user_id: user_id, reason: Log.reason(reason))
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
  def apply_event(user_id, suspended, version) when is_boolean(suspended) do
    result = Repo.impl().apply_suspension(user_id, suspended, version)
    invalidate(user_id)
    result
  end

  @spec invalidate(String.t()) :: :ok
  def invalidate(user_id) do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table, user_id)
    :ok
  end

  defp load(user_id) do
    case Repo.impl().suspended?(user_id) do
      suspended when is_boolean(suspended) ->
        put(user_id, suspended)
        {:ok, suspended}

      {:error, _reason} = error ->
        error
    end
  end

  defp cached(user_id) do
    with true <- :ets.whereis(@table) != :undefined,
         [{^user_id, suspended, expires_at}] <- :ets.lookup(@table, user_id),
         true <- now() < expires_at do
      {:ok, suspended}
    else
      _miss -> :miss
    end
  end

  defp put(user_id, suspended) do
    if :ets.whereis(@table) != :undefined,
      do: :ets.insert(@table, {user_id, suspended, now() + ttl_ms()})

    :ok
  end

  defp ttl_ms, do: Application.get_env(:messaging, :suspension_cache_ttl_ms, @default_ttl_ms)

  defp now, do: System.monotonic_time(:millisecond)
end
