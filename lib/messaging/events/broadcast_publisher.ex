defmodule Messaging.Events.BroadcastPublisher do
  use GenServer
  require Logger

  @behaviour Messaging.Events.Broadcaster

  alias Messaging.Events.Backoff
  alias Messaging.Log

  @exchange "messaging.broadcast"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Messaging.Events.Broadcaster
  def publish(topic, event, payload),
    do: GenServer.call(__MODULE__, {:publish, topic, event, payload})

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    url = Keyword.fetch!(opts, :url)
    send(self(), :connect)
    {:ok, %{url: url, backoff: Backoff.initial(), conn: nil, chan: nil}}
  end

  @impl GenServer
  def handle_call({:publish, _topic, _event, _payload}, _from, %{chan: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:publish, topic, event, payload}, _from, state) do
    body = Jason.encode!(%{"topic" => topic, "event" => event, "payload" => payload})
    result = AMQP.Basic.publish(state.chan, @exchange, "", body, persistent: true)

    {:reply, result, state}
  end

  @impl GenServer
  def handle_info(:connect, state) do
    case connect(state.url) do
      {:ok, conn, chan} ->
        Process.monitor(conn.pid)
        Logger.info("broadcast_publisher_connected", exchange: @exchange)
        {:noreply, %{state | conn: conn, chan: chan, backoff: Backoff.initial()}}

      {:error, reason} ->
        Logger.warning("broadcast_publisher_connect_failed",
          reason: Log.reason(reason),
          retry_in_ms: state.backoff
        )

        Process.send_after(self(), :connect, state.backoff)
        {:noreply, %{state | backoff: Backoff.next(state.backoff)}}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning("broadcast_publisher_connection_down", reason: Log.reason(reason))
    send(self(), :connect)
    {:noreply, %{state | conn: nil, chan: nil, backoff: Backoff.initial()}}
  end

  @impl GenServer
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{conn: conn}) when not is_nil(conn) do
    try do
      AMQP.Connection.close(conn)
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp connect(url) do
    with {:ok, conn} <- AMQP.Connection.open(url),
         {:ok, chan} <- AMQP.Channel.open(conn),
         :ok <- AMQP.Exchange.declare(chan, @exchange, :fanout, durable: true) do
      {:ok, conn, chan}
    end
  end
end
