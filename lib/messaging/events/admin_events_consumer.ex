defmodule Messaging.Events.AdminEventsConsumer do
  @moduledoc """
  Consumes the signed `admin.user_suspended` / `admin.user_reactivated` events
  into the suspended-user state (`Messaging.Suspension`).

  The queue is shared by every instance (competing consumers), so one instance
  gets each event: the state goes to Mongo, which all of them read. An event
  whose signature does not verify never changes anything.
  """

  use GenServer
  require Logger

  alias Messaging.Events.{Audit, Backoff}
  alias Messaging.Log
  alias Messaging.Suspension
  alias Messaging.Suspension.Signature

  @exchange "discordia.events"
  @default_queue "messaging.admin_events"
  @suspended "admin.user_suspended"
  @reactivated "admin.user_reactivated"
  @routing_keys [@suspended, @reactivated]

  def routing_keys, do: @routing_keys

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    secret = Keyword.get_lazy(opts, :secret, &configured_secret/0)

    if secret in [nil, ""] do
      Logger.error("admin_events_consumer_not_started", reason: "empty_hmac_secret")
      :ignore
    else
      Process.flag(:trap_exit, true)
      url = Keyword.fetch!(opts, :url)
      queue = Keyword.get(opts, :queue, @default_queue)
      send(self(), :connect)

      {:ok,
       %{url: url, queue: queue, secret: secret, backoff: Backoff.initial(), conn: nil, chan: nil}}
    end
  end

  @impl true
  def handle_info(:connect, state) do
    case connect(state.url, state.queue) do
      {:ok, conn, chan} ->
        Process.monitor(conn.pid)
        Logger.info("admin_events_consumer_connected", queue: state.queue)
        {:noreply, %{state | conn: conn, chan: chan, backoff: Backoff.initial()}}

      {:error, reason} ->
        Logger.warning("admin_events_consumer_connect_failed",
          reason: Log.reason(reason),
          retry_in_ms: state.backoff
        )

        Process.send_after(self(), :connect, state.backoff)
        {:noreply, %{state | backoff: Backoff.next(state.backoff)}}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning("admin_events_consumer_connection_down", reason: Log.reason(reason))

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
    |> process(meta.routing_key, state.secret)
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
  @spec process(binary(), String.t(), String.t()) :: :ack | :retry
  def process(payload, routing_key, secret) do
    case Jason.decode(payload) do
      {:ok, %{} = decoded} -> handle_decoded(decoded, payload, routing_key, secret)
      {:ok, _not_an_object} -> malformed(payload, routing_key, :not_an_object)
      {:error, reason} -> malformed(payload, routing_key, reason)
    end
  end

  defp finish(:ack, chan, meta), do: AMQP.Basic.ack(chan, meta.delivery_tag)

  defp finish(:retry, chan, meta) do
    Process.sleep(Application.get_env(:messaging, :event_retry_delay_ms, 1_000))
    AMQP.Basic.nack(chan, meta.delivery_tag, requeue: true)
  end

  defp handle_decoded(_decoded, payload, routing_key, _secret)
       when routing_key not in @routing_keys do
    Logger.warning("admin_events_consumer_bad_message",
      reason: "unknown_routing_key",
      routing_key: routing_key
    )

    audit(nil, routing_key, payload, :discarded_unknown_routing_key, "unknown_routing_key")
    :ack
  end

  defp handle_decoded(decoded, payload, routing_key, secret) do
    case parse(routing_key, decoded) do
      {:ok, event} ->
        if Signature.verify(event, secret) do
          apply_event(event, payload)
        else
          invalid_signature(event, payload)
        end

      {:error, reason} ->
        invalid_payload(decoded, payload, routing_key, reason)
    end
  end

  defp parse(
         routing_key,
         %{
           "event_id" => event_id,
           "occurred_at" => occurred_at,
           "user_id" => user_id,
           "version" => version
         } = decoded
       )
       when is_binary(event_id) and event_id != "" and is_binary(occurred_at) and
              is_binary(user_id) and user_id != "" and is_integer(version) do
    {:ok,
     %{
       routing_key: routing_key,
       event_id: event_id,
       occurred_at: occurred_at,
       user_id: user_id,
       version: version,
       signature: Map.get(decoded, "signature")
     }}
  end

  defp parse(_routing_key, _decoded), do: {:error, :invalid_payload}

  defp apply_event(event, payload) do
    suspended = event.routing_key == @suspended

    case Suspension.apply_event(event.user_id, suspended, event.version) do
      {:ok, :applied} ->
        audit(event.event_id, event.routing_key, payload, :processed, nil)
        :ack

      {:ok, :stale} ->
        audit(event.event_id, event.routing_key, payload, :ignored_stale, nil)
        :ack

      {:error, reason} ->
        Logger.error("admin_events_consumer_event_failed",
          reason: Log.reason(reason),
          event_id: event.event_id,
          routing_key: event.routing_key
        )

        :retry
    end
  end

  defp invalid_signature(event, payload) do
    Logger.warning("admin_events_consumer_invalid_signature",
      event_id: event.event_id,
      routing_key: event.routing_key
    )

    audit(
      event.event_id,
      event.routing_key,
      payload,
      :discarded_invalid_signature,
      "invalid_signature"
    )

    :ack
  end

  defp invalid_payload(decoded, payload, routing_key, reason) do
    event_id = Map.get(decoded, "event_id")

    Logger.warning("admin_events_consumer_bad_message",
      reason: Log.reason(reason),
      routing_key: routing_key
    )

    audit(
      if(is_binary(event_id), do: event_id),
      routing_key,
      payload,
      :discarded_invalid_payload,
      inspect(reason)
    )

    :ack
  end

  defp malformed(payload, routing_key, reason) do
    Logger.warning("admin_events_consumer_bad_message",
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

  defp configured_secret, do: Application.get_env(:messaging, :admin_events_hmac_secret)

  defp connect(url, queue) do
    with {:ok, conn} <- AMQP.Connection.open(url),
         {:ok, chan} <- AMQP.Channel.open(conn),
         :ok <- AMQP.Exchange.declare(chan, @exchange, :topic, durable: true),
         {:ok, _info} <- AMQP.Queue.declare(chan, queue, durable: true),
         :ok <- bind_routing_keys(chan, queue),
         {:ok, _consumer_tag} <- AMQP.Basic.consume(chan, queue) do
      {:ok, conn, chan}
    end
  end

  defp bind_routing_keys(chan, queue) do
    Enum.reduce_while(@routing_keys, :ok, fn key, :ok ->
      case AMQP.Queue.bind(chan, queue, @exchange, routing_key: key) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
end
