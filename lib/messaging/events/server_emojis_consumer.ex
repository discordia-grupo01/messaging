defmodule Messaging.Events.ServerEmojisConsumer do
  @moduledoc """
  Consumes `servers.emoji_created` and `servers.emoji_deleted` into the
  `replica_emojis` collection. The two events carry the whole emoji and the
  deletion wins whatever order they arrive in.
  """

  use GenServer
  require Logger

  alias Messaging.Chat.Repo
  alias Messaging.Events.{Audit, Backoff, DeadLetter}
  alias Messaging.Log
  alias Messaging.Tracing

  @exchange "discordia.events"
  @default_queue "messaging.server_emojis"
  @emoji_created "servers.emoji_created"
  @emoji_deleted "servers.emoji_deleted"
  @routing_keys [@emoji_created, @emoji_deleted]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    url = Keyword.fetch!(opts, :url)
    queue = Keyword.get(opts, :queue, @default_queue)
    send(self(), :connect)

    {:ok,
     %{url: url, queue: queue, backoff: Backoff.initial(), conn: nil, chan: nil, attempts: %{}}}
  end

  @impl true
  def handle_info(:connect, state) do
    case connect(state.url, state.queue) do
      {:ok, conn, chan} ->
        Process.monitor(conn.pid)
        Logger.info("server_emojis_consumer_connected", queue: state.queue)
        {:noreply, %{state | conn: conn, chan: chan, backoff: Backoff.initial()}}

      {:error, reason} ->
        Logger.warning("server_emojis_consumer_connect_failed",
          reason: Log.reason(reason),
          retry_in_ms: state.backoff
        )

        Process.send_after(self(), :connect, state.backoff)
        {:noreply, %{state | backoff: Backoff.next(state.backoff)}}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning("server_emojis_consumer_connection_down", reason: Log.reason(reason))

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
    attempts =
      Tracing.consumer_span(meta, state.queue, fn ->
        outcome = process(payload, meta.routing_key)
        Tracing.mark_outcome(outcome)
        DeadLetter.finish(outcome, state, meta, payload)
      end)

    {:noreply, %{state | attempts: attempts}}
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

  defp handle_decoded(_decoded, payload, routing_key)
       when routing_key not in @routing_keys do
    Logger.warning("server_emojis_consumer_bad_message",
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
         "emoji_id" => emoji_id,
         "server_id" => server_id,
         "name" => name,
         "animated" => animated,
         "image_url" => image_url
       }) do
    Enum.all?([event_id, emoji_id, server_id, name, image_url], &(is_binary(&1) and &1 != "")) and
      is_boolean(animated)
  end

  defp valid_shape?(_decoded), do: false

  defp apply_event(event, payload, routing_key) do
    emoji = %{
      "_id" => event["emoji_id"],
      "server_id" => event["server_id"],
      "name" => event["name"],
      "animated" => event["animated"],
      "image_url" => event["image_url"]
    }

    case write(routing_key, emoji) do
      :ok ->
        audit(event["event_id"], routing_key, payload, :processed, nil)
        :ack

      {:error, reason} ->
        Logger.error("server_emojis_consumer_event_failed",
          reason: Log.reason(reason),
          event_id: event["event_id"]
        )

        :retry
    end
  end

  defp write(@emoji_created, emoji), do: Repo.impl().apply_emoji_created(emoji)
  defp write(@emoji_deleted, emoji), do: Repo.impl().apply_emoji_deleted(emoji)

  defp invalid_payload(decoded, payload, routing_key) do
    event_id = Map.get(decoded, "event_id")

    Logger.warning("server_emojis_consumer_bad_message",
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
    Logger.warning("server_emojis_consumer_bad_message",
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
         :ok <- DeadLetter.declare(chan, queue),
         :ok <- bind_all(chan, queue),
         {:ok, _consumer_tag} <- AMQP.Basic.consume(chan, queue) do
      {:ok, conn, chan}
    end
  end

  defp bind_all(chan, queue) do
    Enum.reduce_while(@routing_keys, :ok, fn routing_key, :ok ->
      case AMQP.Queue.bind(chan, queue, @exchange, routing_key: routing_key) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end
end
