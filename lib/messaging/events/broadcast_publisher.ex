defmodule Messaging.Events.BroadcastPublisher do
  use GenServer
  require Logger

  @behaviour Messaging.Events.Broadcaster

  alias Messaging.Events.Backoff

  @exchange "messaging.broadcast"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Messaging.Events.Broadcaster
  def publish(payload), do: GenServer.call(__MODULE__, {:publish, payload})

  @impl GenServer
  def init(opts) do
    url = Keyword.fetch!(opts, :url)
    send(self(), :connect)
    {:ok, %{url: url, backoff: Backoff.initial(), conn: nil, chan: nil}}
  end

  @impl GenServer
  def handle_call({:publish, _payload}, _from, %{chan: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:publish, payload}, _from, state) do
    result =
      AMQP.Basic.publish(state.chan, @exchange, "", Jason.encode!(payload), persistent: true)

    {:reply, result, state}
  end

  @impl GenServer
  def handle_info(:connect, state) do
    case connect(state.url) do
      {:ok, conn, chan} ->
        Process.monitor(conn.pid)
        Logger.info("messaging: broadcast_publisher connected exchange=#{@exchange}")
        {:noreply, %{state | conn: conn, chan: chan, backoff: Backoff.initial()}}

      {:error, reason} ->
        Logger.warning(
          "messaging: broadcast_publisher connect_failed reason=#{inspect(reason)} retry_in_ms=#{state.backoff}"
        )

        Process.send_after(self(), :connect, state.backoff)
        {:noreply, %{state | backoff: Backoff.next(state.backoff)}}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning("messaging: broadcast_publisher connection_down reason=#{inspect(reason)}")
    send(self(), :connect)
    {:noreply, %{state | conn: nil, chan: nil, backoff: Backoff.initial()}}
  end

  defp connect(url) do
    with {:ok, conn} <- AMQP.Connection.open(url),
         {:ok, chan} <- AMQP.Channel.open(conn),
         :ok <- AMQP.Exchange.declare(chan, @exchange, :fanout, durable: true) do
      {:ok, conn, chan}
    end
  end
end
