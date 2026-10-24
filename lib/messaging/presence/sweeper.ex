defmodule Messaging.Presence.Sweeper do
  use GenServer
  require Logger

  alias Messaging.Log
  alias Messaging.Presence
  alias Messaging.Presence.Store

  @default_interval_ms 15_000
  @default_stale_after_ms 30_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  @spec sweep(DateTime.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def sweep(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -stale_after_ms(), :millisecond)

    with {:ok, instance_ids} <- Store.impl().stale_instances(cutoff) do
      {:ok, Enum.count(instance_ids, &(sweep_instance(&1) == :ok))}
    end
  end

  defp sweep_instance(instance_id) do
    with {:ok, user_ids} <- Store.impl().user_ids_on_instance(instance_id),
         :ok <- drop_all(user_ids, instance_id),
         :ok <- Store.impl().delete_instance(instance_id) do
      Logger.info("presence_instance_swept", instance_id: instance_id, users: length(user_ids))
    else
      {:error, reason} ->
        Logger.warning("presence_sweep_failed",
          instance_id: instance_id,
          reason: Log.reason(reason)
        )

        :error
    end
  end

  defp drop_all(user_ids, instance_id) do
    user_ids
    |> Enum.map(&Presence.drop_instance(&1, instance_id))
    |> Enum.find(:ok, &match?({:error, _reason}, &1))
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    Process.send_after(self(), :sweep, interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:sweep, state) do
    case sweep() do
      {:ok, _count} -> :ok
      {:error, reason} -> Logger.warning("presence_sweep_failed", reason: Log.reason(reason))
    end

    Process.send_after(self(), :sweep, state.interval)
    {:noreply, state}
  end

  defp stale_after_ms,
    do: Application.get_env(:messaging, :presence, [])[:stale_after_ms] || @default_stale_after_ms
end
