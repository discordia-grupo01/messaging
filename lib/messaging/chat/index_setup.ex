defmodule Messaging.Chat.IndexSetup do
  use Task, restart: :transient

  require Logger

  @default_retry_ms 2_000
  @max_attempts 30

  def start_link(opts), do: Task.start_link(__MODULE__, :run, [opts])

  @spec run(keyword()) :: :ok
  def run(opts \\ []), do: attempt(1, Keyword.get(opts, :retry_ms, @default_retry_ms))

  defp attempt(n, retry_ms) do
    case repo().ensure_indexes() do
      :ok ->
        Logger.info("messaging: indexes_ready attempts=#{n}")

      {:error, reason} when n < @max_attempts ->
        Logger.warning("messaging: indexes_retry attempt=#{n} reason=#{inspect(reason)}")
        Process.sleep(retry_ms)
        attempt(n + 1, retry_ms)

      {:error, reason} ->
        Logger.error("messaging: indexes_failed attempts=#{n} reason=#{inspect(reason)}")
    end
  end

  defp repo, do: Application.get_env(:messaging, :chat_repo, Messaging.Chat.Repo.Mongo)
end
