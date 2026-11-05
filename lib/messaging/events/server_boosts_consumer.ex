defmodule Messaging.Events.ServerBoostsConsumer do
  @moduledoc """
  Consumes `servers.server_boost_updated` into the `server_boosts` collection.
  Each event is the server's whole state, and it only applies if its version is
  higher than the stored one, so repeated or disordered deliveries do no harm.
  """

  use GenServer
  require Logger

  alias Messaging.Chat.Repo
  alias Messaging.Events.{Audit, Backoff}
  alias Messaging.Log

  @exchange "discordia.events"
  @default_queue "messaging.server_boosts"
  @boost_updated "servers.server_boost_updated"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    url = Keyword.fetch!(opts, :url)
    queue = Keyword.get(opts, :queue, @default_queue)
    send(self(), :connect)
    {:ok, %{url: url, queue: queue, backoff: Backoff.initial(), conn: nil, chan: nil}}
  end

  @impl true
  def handle_info(:connect, state) do
    case connect(state.url, state.queue) do
      {:ok, conn, chan} ->
        Process.monitor(conn.pid)
        Logger.info("server_boosts_consumer_connected", queue: state.queue)
        {:noreply, %{state | conn: conn, chan: chan, backoff: Backoff.initial()}}

      {:error, reason} ->
        Logger.warning("server_boosts_consumer_connect_failed",
          reason: Log.reason(reason),
          retry_in_ms: state.backoff
        )

        Process.send_after(self(), :connect, state.backoff)
        {:noreply, %{state | backoff: Backoff.next(state.backoff)}}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning("server_boosts_consumer_connection_down", reason: Log.reason(reason))

    send(self(), :connect)
    {:noreply, %{state | conn: nil, chan: nil, backoff: Backoff.initial()}}
  end

  @impl true
  def handle_info({:basic_consume_ok, _meta}, state), do: {:noreply, state}

  @impl true
  def handle_info({:basic_cancel, _meta}, state), do: {:stop, :normal, state}

  @impl true
  def handle_info({:basic_cancel_ok, _meta}, state), do: {:noreply, state}

  @impl true
  def handle_info({:basic_deliver, payload, meta}, state) do
    payload
    |> process(meta.routing_key)
    |> finish(state.chan, meta)

    {:noreply, state}
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

  @doc false
  @spec process(binary(), String.t()) :: :ack | :retry
  def process(payload, routing_key) do
    case Jason.decode(payload) do
      {:ok, %{} = decoded} -> handle_decoded(decoded, payload, routing_key)
      {:ok, _not_an_object} -> malformed(payload, routing_key, :not_an_object)
      {:error, reason} -> malformed(payload, routing_key, reason)
    end
  end

  defp finish(:ack, chan, meta), do: AMQP.Basic.ack(chan, meta.delivery_tag)

  defp finish(:retry, chan, meta) do
    Process.sleep(Application.get_env(:messaging, :event_retry_delay_ms, 1_000))
    AMQP.Basic.nack(chan, meta.delivery_tag, requeue: true)
  end

  defp handle_decoded(_decoded, payload, routing_key)
       when routing_key != @boost_updated do
    Logger.warning("server_boosts_consumer_bad_message",
      reason: "unknown_routing_key",
      routing_key: routing_key
    )

    audit(nil, routing_key, payload, :discarded_unknown_routing_key, "unknown_routing_key")
    :ack
  end

  defp handle_decoded(decoded, payload, routing_key) do
    if valid_shape?(decoded),
      do: apply_event(decoded, payload, routing_key),
      else: invalid_payload(decoded, payload, routing_key)
  end

  defp valid_shape?(%{
         "event_id" => event_id,
         "server_id" => server_id,
         "level" => level,
         "version" => version
       }) do
    is_binary(event_id) and event_id != "" and is_binary(server_id) and server_id != "" and
      level in 0..3 and is_integer(version) and version > 0
  end

  defp valid_shape?(_decoded), do: false

  defp apply_event(event, payload, routing_key) do
    case Repo.impl().apply_server_boost(event["server_id"], event["level"], event["version"]) do
      {:ok, :applied} ->
        audit(event["event_id"], routing_key, payload, :processed, nil)
        :ack

      {:ok, :stale} ->
        audit(event["event_id"], routing_key, payload, :ignored_stale, nil)
        :ack

      {:error, reason} ->
        Logger.error("server_boosts_consumer_event_failed",
          reason: Log.reason(reason),
          event_id: event["event_id"]
        )

        :retry
    end
  end

  defp invalid_payload(decoded, payload, routing_key) do
    event_id = Map.get(decoded, "event_id")

    Logger.warning("server_boosts_consumer_bad_message",
      reason: "invalid_payload",
      routing_key: routing_key
    )

    audit(
      if(is_binary(event_id), do: event_id),
      routing_key,
      payload,
      :discarded_invalid_payload,
      "invalid_payload"
    )

    :ack
  end

  defp malformed(payload, routing_key, reason) do
    Logger.warning("server_boosts_consumer_bad_message",
      reason: Log.reason(reason),
      routing_key: routing_key
    )

    audit(nil, routing_key, payload, :discarded_malformed_payload, inspect(reason))
    :ack
  end

  defp audit(event_id, routing_key, payload, status, error) do
    Audit.record(%{
      event_id: event_id,
      routing_key: routing_key,
      raw_body: payload,
      status: status,
      error: error
    })
  end

  defp connect(url, queue) do
    with {:ok, conn} <- AMQP.Connection.open(url),
         {:ok, chan} <- AMQP.Channel.open(conn),
         :ok <- AMQP.Exchange.declare(chan, @exchange, :topic, durable: true),
         {:ok, _info} <- AMQP.Queue.declare(chan, queue, durable: true),
         :ok <- AMQP.Queue.bind(chan, queue, @exchange, routing_key: @boost_updated),
         {:ok, _consumer_tag} <- AMQP.Basic.consume(chan, queue) do
      {:ok, conn, chan}
    end
  end
end
