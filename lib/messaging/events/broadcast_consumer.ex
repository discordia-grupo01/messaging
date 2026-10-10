defmodule Messaging.Events.BroadcastConsumer do
  use GenServer
  require Logger

  alias Messaging.Events.Backoff
  alias Messaging.Log

  @exchange "messaging.broadcast"
  @events [
    "new_message",
    "message_updated",
    "message_deleted",
    "reaction_updated",
    "new_dm",
    "mention",
    "access_revoked"
  ]
  @topic_prefixes ["channel:", "user:"]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    url = Keyword.fetch!(opts, :url)
    send(self(), :connect)
    {:ok, %{url: url, backoff: Backoff.initial(), conn: nil, chan: nil}}
  end

  @impl true
  def handle_info(:connect, state) do
    case connect(state.url) do
      {:ok, conn, chan} ->
        Process.monitor(conn.pid)
        Logger.info("broadcast_consumer_connected", exchange: @exchange)
        {:noreply, %{state | conn: conn, chan: chan, backoff: Backoff.initial()}}

      {:error, reason} ->
        Logger.warning("broadcast_consumer_connect_failed",
          reason: Log.reason(reason),
          retry_in_ms: state.backoff
        )

        Process.send_after(self(), :connect, state.backoff)
        {:noreply, %{state | backoff: Backoff.next(state.backoff)}}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning("broadcast_consumer_connection_down", reason: Log.reason(reason))
    send(self(), :connect)
    {:noreply, %{state | conn: nil, chan: nil, backoff: Backoff.initial()}}
  end

  @impl GenServer
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def handle_info({:basic_consume_ok, _meta}, state), do: {:noreply, state}

  @impl true
  def handle_info({:basic_cancel, _meta}, state), do: {:stop, :normal, state}

  @impl true
  def handle_info({:basic_cancel_ok, _meta}, state), do: {:noreply, state}

  @impl true
  def handle_info({:basic_deliver, payload, meta}, state) do
    deliver_locally(payload)
    AMQP.Basic.ack(state.chan, meta.delivery_tag)
    {:noreply, state}
  end

  defp deliver_locally(body) do
    with {:ok, decoded} <- Jason.decode(body),
         {:ok, event, topic, payload} <- unwrap(decoded) do
      MessagingWeb.Endpoint.broadcast!(topic, event, payload)
    else
      {:error, reason} ->
        Logger.warning("broadcast_consumer_bad_message", reason: Log.reason(reason))

      _other ->
        Logger.warning("broadcast_consumer_bad_message", reason: "invalid_payload")
    end
  end

  defp unwrap(%{"event" => event, "payload" => payload} = decoded) when event in @events do
    case topic_for(decoded, payload) do
      {:ok, topic} -> {:ok, event, topic, payload}
      :error -> {:error, :invalid_payload}
    end
  end

  defp unwrap(%{"event" => _unknown}), do: {:error, :unknown_event}

  defp unwrap(%{"channel_id" => channel_id} = legacy_message) when is_binary(channel_id),
    do: {:ok, "new_message", "channel:" <> channel_id, legacy_message}

  defp unwrap(_other), do: {:error, :invalid_payload}

  defp topic_for(%{"topic" => topic}, _payload) when is_binary(topic) do
    if String.starts_with?(topic, @topic_prefixes), do: {:ok, topic}, else: :error
  end

  defp topic_for(_decoded, %{"channel_id" => channel_id}) when is_binary(channel_id),
    do: {:ok, "channel:" <> channel_id}

  defp topic_for(_decoded, _payload), do: :error

  defp connect(url) do
    with {:ok, conn} <- AMQP.Connection.open(url),
         {:ok, chan} <- AMQP.Channel.open(conn),
         :ok <- AMQP.Exchange.declare(chan, @exchange, :fanout, durable: true),
         {:ok, %{queue: queue}} <-
           AMQP.Queue.declare(chan, "", exclusive: true, auto_delete: true),
         :ok <- AMQP.Queue.bind(chan, queue, @exchange),
         {:ok, _consumer_tag} <- AMQP.Basic.consume(chan, queue) do
      {:ok, conn, chan}
    end
  end

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
end
