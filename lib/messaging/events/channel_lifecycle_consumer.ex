defmodule Messaging.Events.ChannelLifecycleConsumer do
  use GenServer
  require Logger

  alias Messaging.Chat
  alias Messaging.Chat.ChannelCache
  alias Messaging.Events.{Audit, Backoff, ChannelEvent}

  @exchange "discordia.events"
  @default_queue "messaging.channel_lifecycle"
  @routing_keys [
    ChannelEvent.routing_key_channel_created(),
    ChannelEvent.routing_key_channel_deleted(),
    ChannelEvent.routing_key_server_deleted()
  ]

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
        Logger.info("messaging: channel_lifecycle_consumer connected queue=#{state.queue}")
        {:noreply, %{state | conn: conn, chan: chan, backoff: Backoff.initial()}}

      {:error, reason} ->
        Logger.warning(
          "messaging: channel_lifecycle_consumer connect_failed reason=#{inspect(reason)} retry_in_ms=#{state.backoff}"
        )

        Process.send_after(self(), :connect, state.backoff)
        {:noreply, %{state | backoff: Backoff.next(state.backoff)}}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning(
      "messaging: channel_lifecycle_consumer connection_down reason=#{inspect(reason)}"
    )

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
    handle_delivery(payload, meta, state.chan)
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

  defp handle_delivery(payload, meta, chan) do
    case Jason.decode(payload) do
      {:ok, decoded} -> handle_decoded(decoded, payload, meta)
      {:error, reason} -> handle_malformed(payload, meta, reason)
    end

    AMQP.Basic.ack(chan, meta.delivery_tag)
  end

  defp handle_decoded(decoded, payload, meta) do
    case ChannelEvent.parse(meta.routing_key, decoded) do
      {:ok, event} ->
        apply_event(event)

        Audit.record(%{
          event_id: event.event_id,
          routing_key: meta.routing_key,
          raw_body: payload,
          status: :processed,
          error: nil
        })

      {:error, reason} ->
        Logger.warning(
          "messaging: channel_lifecycle_consumer bad_message reason=#{inspect(reason)} routing_key=#{meta.routing_key}"
        )

        Audit.record(%{
          event_id: Map.get(decoded, "event_id"),
          routing_key: meta.routing_key,
          raw_body: payload,
          status: discard_status(reason),
          error: inspect(reason)
        })
    end
  end

  defp handle_malformed(payload, meta, reason) do
    Logger.warning(
      "messaging: channel_lifecycle_consumer bad_message reason=#{inspect(reason)} routing_key=#{meta.routing_key}"
    )

    Audit.record(%{
      event_id: nil,
      routing_key: meta.routing_key,
      raw_body: payload,
      status: :discarded_malformed_payload,
      error: inspect(reason)
    })
  end

  defp discard_status(:unknown_routing_key), do: :discarded_unknown_routing_key
  defp discard_status(:invalid_payload), do: :discarded_invalid_payload

  defp apply_event(%ChannelEvent.ChannelCreated{} = event) do
    :ok =
      Chat.upsert_channel(%ChannelCache{
        channel_id: event.channel_id,
        server_id: event.server_id,
        name: event.name,
        kind: event.kind
      })

    Logger.info("messaging: channel_created_applied channel_id=#{event.channel_id}")
  end

  defp apply_event(%ChannelEvent.ChannelDeleted{} = event) do
    :ok = Chat.delete_channel(event.channel_id)
    Logger.info("messaging: channel_deleted_applied channel_id=#{event.channel_id}")
  end

  defp apply_event(%ChannelEvent.ServerDeleted{} = event) do
    :ok = Chat.delete_server_data(event.server_id, event.channel_ids)

    Logger.info(
      "messaging: server_deleted_applied server_id=#{event.server_id} channels=#{length(event.channel_ids)}"
    )
  end

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
