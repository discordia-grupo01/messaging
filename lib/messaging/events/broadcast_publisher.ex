defmodule Messaging.Events.BroadcastPublisher do
  use GenServer
  require Logger

  @behaviour Messaging.Events.EventPublisher

  alias Messaging.Events.{Backoff, DomainEvent}
  alias Messaging.Log
  alias Messaging.Tracing

  @exchange "messaging.broadcast"
  @events_exchange "discordia.events"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @confirm_timeout_ms 5_000

  @impl Messaging.Events.EventPublisher
  def publish_event(id, topic, event, payload) do
    headers = Tracing.amqp_headers()

    GenServer.call(
      __MODULE__,
      {:publish, id, topic, event, payload, headers},
      @confirm_timeout_ms * 2
    )
  catch
    :exit, reason -> {:error, reason}
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    url = Keyword.fetch!(opts, :url)
    send(self(), :connect)
    {:ok, %{url: url, backoff: Backoff.initial(), conn: nil, chan: nil}}
  end

  @impl GenServer
  def handle_call(
        {:publish, _id, _topic, _event, _payload, _headers},
        _from,
        %{chan: nil} = state
      ) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:publish, id, topic, event, payload, headers}, _from, state) do
    domain_topic = DomainEvent.topic()

    result =
      case topic do
        ^domain_topic -> publish_domain(state.chan, id, event, payload, headers)
        _channel_topic -> publish_broadcast(state.chan, id, topic, event, payload, headers)
      end

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

  defp publish_broadcast(chan, id, topic, event, payload, headers) do
    body =
      Jason.encode!(%{"event_id" => id, "topic" => topic, "event" => event, "payload" => payload})

    with :ok <-
           AMQP.Basic.publish(chan, @exchange, "", body,
             persistent: true,
             message_id: id,
             headers: headers
           ) do
      confirm(chan)
    end
  end

  defp publish_domain(chan, id, routing_key, payload, headers) do
    body = payload |> Map.put("event_id", id) |> Jason.encode!()

    with :ok <-
           AMQP.Basic.publish(chan, @events_exchange, routing_key, body,
             persistent: true,
             message_id: id,
             content_type: "application/json",
             headers: headers
           ) do
      confirm(chan)
    end
  end

  defp connect(url) do
    with {:ok, conn} <- AMQP.Connection.open(url),
         {:ok, chan} <- AMQP.Channel.open(conn),
         :ok <- AMQP.Exchange.declare(chan, @exchange, :fanout, durable: true),
         :ok <- AMQP.Exchange.declare(chan, @events_exchange, :topic, durable: true),
         :ok <- AMQP.Confirm.select(chan) do
      {:ok, conn, chan}
    end
  end

  defp confirm(chan) do
    case AMQP.Confirm.wait_for_confirms(chan, @confirm_timeout_ms) do
      true -> :ok
      false -> {:error, :not_confirmed}
      :timeout -> {:error, :confirm_timeout}
    end
  end
end
