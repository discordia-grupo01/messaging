defmodule Messaging.Events.DeadLetter do
  require Logger

  alias Messaging.Log

  @exchange "discordia.dlx"
  @suffix ".dlq"
  @reason "retries_exhausted"
  @default_max_attempts 5
  @default_base_delay_ms 1_000
  @max_delay_ms 30_000
  @jitter 0.2
  @max_tracked 1_024
  @confirm_timeout_ms 5_000

  def exchange, do: @exchange
  def queue_for(queue), do: queue <> @suffix

  def declare(chan, queue) do
    dead_letter_queue = queue_for(queue)

    with :ok <- AMQP.Exchange.declare(chan, @exchange, :direct, durable: true),
         {:ok, _info} <- AMQP.Queue.declare(chan, dead_letter_queue, durable: true),
         :ok <- AMQP.Queue.bind(chan, dead_letter_queue, @exchange, routing_key: queue) do
      :ok
    end
  end

  def max_attempts,
    do: Application.get_env(:messaging, :event_max_attempts, @default_max_attempts)

  def delay(attempt, random) when attempt >= 1 and random >= 0 and random <= 1 do
    base = Application.get_env(:messaging, :event_retry_delay_ms, @default_base_delay_ms)
    capped = min(base * Integer.pow(2, min(attempt - 1, 20)), @max_delay_ms)
    round(capped * (1 + @jitter * (2 * random - 1)))
  end

  def identity(routing_key, payload) do
    :crypto.hash(:sha256, [routing_key, 0, payload]) |> Base.encode16(case: :lower)
  end

  def finish(:ack, state, meta, payload) do
    AMQP.Basic.ack(state.chan, meta.delivery_tag)
    Map.delete(state.attempts, identity(meta.routing_key, payload))
  end

  def finish(:retry, state, meta, payload) do
    key = identity(meta.routing_key, payload)
    attempt = Map.get(state.attempts, key, 0) + 1

    case move_if_exhausted(state, meta, payload, attempt) do
      :moved ->
        AMQP.Basic.ack(state.chan, meta.delivery_tag)
        Map.delete(state.attempts, key)

      :retry ->
        wait = delay(attempt, :rand.uniform())

        Logger.warning("event_attempt_failed",
          queue: state.queue,
          routing_key: meta.routing_key,
          event_id: event_id(payload),
          attempt: attempt,
          retry_in_ms: wait
        )

        Process.sleep(wait)
        AMQP.Basic.nack(state.chan, meta.delivery_tag, requeue: true)
        track(state.attempts, key, attempt)
    end
  end

  defp move_if_exhausted(state, meta, payload, attempt) do
    if attempt >= max_attempts() do
      case publish(state.conn, state.queue, meta, payload, attempt) do
        :ok ->
          Logger.error("event_moved_to_dead_letter_queue",
            queue: state.queue,
            routing_key: meta.routing_key,
            event_id: event_id(payload),
            attempts: attempt
          )

          :moved

        {:error, reason} ->
          Logger.error("event_dead_letter_publish_failed",
            queue: state.queue,
            routing_key: meta.routing_key,
            event_id: event_id(payload),
            reason: Log.reason(reason)
          )

          :retry
      end
    else
      :retry
    end
  end

  defp track(attempts, key, attempt) when map_size(attempts) >= @max_tracked,
    do: Map.put(%{}, key, attempt)

  defp track(attempts, key, attempt), do: Map.put(attempts, key, attempt)

  defp publish(conn, queue, meta, payload, attempt) do
    with {:ok, chan} <- AMQP.Channel.open(conn) do
      try do
        with :ok <- AMQP.Confirm.select(chan),
             :ok <-
               AMQP.Basic.publish(
                 chan,
                 @exchange,
                 queue,
                 payload,
                 options(queue, meta, payload, attempt)
               ) do
          confirmed(AMQP.Confirm.wait_for_confirms(chan, @confirm_timeout_ms))
        end
      after
        close(chan)
      end
    end
  end

  defp confirmed(true), do: :ok
  defp confirmed(false), do: {:error, :not_confirmed}
  defp confirmed(:timeout), do: {:error, :confirm_timeout}

  defp options(queue, meta, payload, attempt) do
    headers =
      [
        {"x-original-queue", :longstr, queue},
        {"x-original-exchange", :longstr, to_string(Map.get(meta, :exchange, ""))},
        {"x-original-routing-key", :longstr, meta.routing_key},
        {"x-failure-reason", :longstr, @reason},
        {"x-attempts", :long, attempt},
        {"x-failed-at", :longstr, DateTime.to_iso8601(DateTime.utc_now())}
      ] ++ event_id_header(payload)

    [persistent: true, content_type: "application/json", headers: headers]
  end

  defp event_id_header(payload) do
    case event_id(payload) do
      nil -> []
      id -> [{"x-event-id", :longstr, id}]
    end
  end

  defp event_id(payload) do
    case Jason.decode(payload) do
      {:ok, %{"event_id" => id}} when is_binary(id) -> id
      _other -> nil
    end
  end

  defp close(chan) do
    AMQP.Channel.close(chan)
  catch
    :exit, _ -> :ok
  end
end
