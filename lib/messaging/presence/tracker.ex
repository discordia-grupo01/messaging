defmodule Messaging.Presence.Tracker do
  use GenServer
  require Logger

  alias Messaging.Log
  alias Messaging.Presence
  alias Messaging.Presence.Store
  alias Messaging.UUID

  @default_heartbeat_ms 10_000
  @track_timeout_ms 5_000
  @disconnect_retries 3
  @retry_delay_ms 1_000

  @type tracked :: %{conn_id: String.t(), status: String.t()}

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec track(GenServer.server(), pid(), String.t()) ::
          {:ok, tracked()} | :untracked | {:error, term()}
  def track(server \\ __MODULE__, channel_pid, user_id) do
    case GenServer.whereis(server) do
      nil -> :untracked
      pid -> GenServer.call(pid, {:track, channel_pid, user_id}, @track_timeout_ms)
    end
  catch
    :exit, reason -> {:error, {:tracker_unavailable, reason}}
  end

  @spec instance_id(GenServer.server()) :: String.t()
  def instance_id(server \\ __MODULE__), do: GenServer.call(server, :instance_id)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      instance_id: Keyword.get_lazy(opts, :instance_id, &UUID.generate/0),
      heartbeat_ms: Keyword.get(opts, :heartbeat_ms, heartbeat_ms()),
      connections: %{}
    }

    Logger.info("presence_tracker_started", instance_id: state.instance_id)
    {:ok, beat(state)}
  end

  @impl true
  def handle_call({:track, channel_pid, user_id}, _from, state) do
    conn_id = UUID.generate()
    ref = Process.monitor(channel_pid)

    case Presence.connect(user_id, conn_id, state.instance_id) do
      {:ok, status} ->
        connections = Map.put(state.connections, ref, {user_id, conn_id})
        {:reply, {:ok, %{conn_id: conn_id, status: status}}, %{state | connections: connections}}

      {:error, _reason} = error ->
        Process.demonitor(ref, [:flush])
        {:reply, error, state}
    end
  end

  def handle_call(:instance_id, _from, state), do: {:reply, state.instance_id, state}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.connections, ref) do
      {nil, _connections} ->
        {:noreply, state}

      {{user_id, conn_id}, connections} ->
        disconnect(user_id, conn_id, 1)
        {:noreply, %{state | connections: connections}}
    end
  end

  def handle_info({:retry_disconnect, user_id, conn_id, attempt}, state) do
    disconnect(user_id, conn_id, attempt)
    {:noreply, state}
  end

  def handle_info(:heartbeat, state), do: {:noreply, beat(state)}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state.connections
    |> Map.values()
    |> Enum.map(fn {user_id, _conn_id} -> user_id end)
    |> Enum.uniq()
    |> Enum.each(&Presence.drop_instance(&1, state.instance_id))

    Store.impl().delete_instance(state.instance_id)
    :ok
  end

  defp disconnect(user_id, conn_id, attempt) do
    case Presence.disconnect(user_id, conn_id) do
      :ok ->
        :ok

      {:error, reason} when attempt < @disconnect_retries ->
        Logger.warning("presence_disconnect_retry",
          user_id: user_id,
          attempt: attempt,
          reason: Log.reason(reason)
        )

        Process.send_after(
          self(),
          {:retry_disconnect, user_id, conn_id, attempt + 1},
          @retry_delay_ms
        )

      {:error, _reason} ->
        :ok
    end
  end

  defp beat(state) do
    case Store.impl().heartbeat(state.instance_id, DateTime.utc_now()) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("presence_heartbeat_failed",
          instance_id: state.instance_id,
          reason: Log.reason(reason)
        )
    end

    Process.send_after(self(), :heartbeat, state.heartbeat_ms)
    state
  end

  defp heartbeat_ms,
    do: Application.get_env(:messaging, :presence, [])[:heartbeat_ms] || @default_heartbeat_ms
end
