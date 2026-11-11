defmodule Messaging.Events.BillingEventsConsumer do
  @moduledoc """
  Consumes the signed `billing.premium_updated` events into the Premium state
  (`Messaging.Premium`).

  The queue is shared by every instance (competing consumers), so one instance
  gets each event: the state goes to Mongo, which all of them read. An event
  whose signature does not verify never changes anything.
  """

  use GenServer
  require Logger

  alias Messaging.Events.{Audit, Backoff, Contract, DeadLetter}
  alias Messaging.Log
  alias Messaging.Tracing
  alias Messaging.Premium
  alias Messaging.Premium.Signature

  @exchange "discordia.events"
  @default_queue "messaging.billing_events"
  @premium_updated "billing.premium_updated"

  def routing_key, do: @premium_updated

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    secret = Keyword.get_lazy(opts, :secret, &configured_secret/0)

    if secret in [nil, ""] do
      Logger.error("billing_events_consumer_not_started", reason: "empty_hmac_secret")
      :ignore
    else
      Process.flag(:trap_exit, true)
      url = Keyword.fetch!(opts, :url)
      queue = Keyword.get(opts, :queue, @default_queue)
      send(self(), :connect)

      {:ok,
       %{
         url: url,
         queue: queue,
         secret: secret,
         backoff: Backoff.initial(),
         conn: nil,
         chan: nil,
         attempts: %{}
       }}
    end
  end

  @impl true
  def handle_info(:connect, state) do
    case connect(state.url, state.queue) do
      {:ok, conn, chan} ->
        Process.monitor(conn.pid)
        Logger.info("billing_events_consumer_connected", queue: state.queue)
        {:noreply, %{state | conn: conn, chan: chan, backoff: Backoff.initial()}}

      {:error, reason} ->
        Logger.warning("billing_events_consumer_connect_failed",
          reason: Log.reason(reason),
          retry_in_ms: state.backoff
        )

        Process.send_after(self(), :connect, state.backoff)
        {:noreply, %{state | backoff: Backoff.next(state.backoff)}}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning("billing_events_consumer_connection_down", reason: Log.reason(reason))

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
        outcome = process(payload, meta.routing_key, state.secret)
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
  @spec process(binary(), String.t(), String.t()) :: :ack | :retry
  def process(payload, routing_key, secret) do
    case Jason.decode(payload) do
      {:ok, %{} = decoded} -> handle_decoded(decoded, payload, routing_key, secret)
      {:ok, _not_an_object} -> malformed(payload, routing_key, :not_an_object)
      {:error, reason} -> malformed(payload, routing_key, reason)
    end
  end

  defp handle_decoded(_decoded, payload, routing_key, _secret)
       when routing_key != @premium_updated do
    Logger.warning("billing_events_consumer_bad_message",
      reason: "unknown_routing_key",
      routing_key: routing_key
    )

    audit(nil, routing_key, payload, :discarded_unknown_routing_key, "unknown_routing_key")
    :ack
  end

  defp handle_decoded(decoded, payload, routing_key, secret) do
    Contract.check(routing_key, decoded)

    cond do
      not valid_shape?(decoded) ->
        invalid_payload(decoded, payload, routing_key)

      Signature.verify(decoded, secret) ->
        apply_event(decoded, payload)

      true ->
        invalid_signature(decoded, payload)
    end
  end

  defp valid_shape?(%{
         "event_id" => event_id,
         "occurred_at" => occurred_at,
         "user_id" => user_id,
         "active" => active,
         "premium_until" => premium_until,
         "renews" => renews,
         "version" => version
       }) do
    is_binary(event_id) and event_id != "" and is_binary(occurred_at) and is_binary(user_id) and
      user_id != "" and is_boolean(active) and (is_binary(premium_until) or is_nil(premium_until)) and
      is_boolean(renews) and is_integer(version)
  end

  defp valid_shape?(_decoded), do: false

  defp apply_event(event, payload) do
    case Premium.apply_event(event["user_id"], event["active"], event["version"]) do
      {:ok, :applied} ->
        audit(event["event_id"], @premium_updated, payload, :processed, nil)
        :ack

      {:ok, :stale} ->
        audit(event["event_id"], @premium_updated, payload, :ignored_stale, nil)
        :ack

      {:error, reason} ->
        Logger.error("billing_events_consumer_event_failed",
          reason: Log.reason(reason),
          event_id: event["event_id"]
        )

        :retry
    end
  end

  defp invalid_signature(event, payload) do
    Logger.warning("billing_events_consumer_invalid_signature", event_id: event["event_id"])

    audit(
      event["event_id"],
      @premium_updated,
      payload,
      :discarded_invalid_signature,
      "invalid_signature"
    )

    :ack
  end

  defp invalid_payload(decoded, payload, routing_key) do
    event_id = Map.get(decoded, "event_id")

    Logger.warning("billing_events_consumer_bad_message",
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
    Logger.warning("billing_events_consumer_bad_message",
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

  defp configured_secret, do: Application.get_env(:messaging, :billing_events_hmac_secret)

  defp connect(url, queue) do
    with {:ok, conn} <- AMQP.Connection.open(url),
         {:ok, chan} <- AMQP.Channel.open(conn),
         :ok <- AMQP.Exchange.declare(chan, @exchange, :topic, durable: true),
         {:ok, _info} <- AMQP.Queue.declare(chan, queue, durable: true),
         :ok <- DeadLetter.declare(chan, queue),
         :ok <- AMQP.Queue.bind(chan, queue, @exchange, routing_key: @premium_updated),
         {:ok, _consumer_tag} <- AMQP.Basic.consume(chan, queue) do
      {:ok, conn, chan}
    end
  end
end
