defmodule Messaging.Events.AdminEventsConsumer do
  @moduledoc """
  Consumes the signed `admin.user_suspended` / `admin.user_reactivated` events
  into the suspended-user state (`Messaging.Suspension`) and the signed
  `admin.server_suspended` / `admin.server_reactivated` events into the
  suspended-server state (`Messaging.ServerSuspension`). Suspending a server also
  cuts the sockets of all its channels, and both server events tell each member's
  personal room (`server_suspended` / `server_reactivated`). `admin.server_deletion_requested` is not
  consumed here: servers runs the deletion and messaging reacts to the
  `servers.server_deleted` it publishes.

  The queue is shared by every instance (competing consumers), so one instance
  gets each event: the state goes to Mongo, which all of them read. An event
  whose signature does not verify never changes anything.
  """

  use GenServer
  require Logger

  alias Messaging.Chat.{Repo, Sockets}
  alias Messaging.Events.{Audit, Backoff, Broadcaster, Contract, DeadLetter, EventPublisher}
  alias Messaging.Log
  alias Messaging.Tracing
  alias Messaging.ServerSuspension
  alias Messaging.Suspension
  alias Messaging.Suspension.Signature

  @exchange "discordia.events"
  @default_queue "messaging.admin_events"
  @suspended "admin.user_suspended"
  @reactivated "admin.user_reactivated"
  @server_suspended "admin.server_suspended"
  @server_reactivated "admin.server_reactivated"
  @server_keys [@server_suspended, @server_reactivated]
  @routing_keys [@suspended, @reactivated] ++ @server_keys

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
       when routing_key not in @routing_keys do
    Logger.warning("admin_events_consumer_bad_message",
      reason: "unknown_routing_key",
      routing_key: routing_key
    )

    audit(nil, routing_key, payload, :discarded_unknown_routing_key, "unknown_routing_key")
    :ack
  end

  defp handle_decoded(decoded, payload, routing_key, secret) do
    Contract.check(routing_key, decoded)

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

  # Server events name a server and their version starts at 1, as admin counts.
  defp parse(
         routing_key,
         %{
           "event_id" => event_id,
           "occurred_at" => occurred_at,
           "server_id" => server_id,
           "version" => version
         } = decoded
       )
       when routing_key in @server_keys and is_binary(event_id) and event_id != "" and
              is_binary(occurred_at) and is_binary(server_id) and server_id != "" and
              is_integer(version) and version >= 1 do
    {:ok,
     %{
       routing_key: routing_key,
       event_id: event_id,
       occurred_at: occurred_at,
       server_id: server_id,
       version: version,
       signature: Map.get(decoded, "signature")
     }}
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
       when routing_key not in @server_keys and is_binary(event_id) and event_id != "" and
              is_binary(occurred_at) and is_binary(user_id) and user_id != "" and
              is_integer(version) do
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

  defp apply_event(%{server_id: server_id} = event, payload) do
    suspended = event.routing_key == @server_suspended

    case ServerSuspension.apply_event(server_id, suspended, event.version) do
      {:ok, :applied} ->
        if suspended, do: close_server_sockets(server_id)
        notify_members(server_id, suspended)
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

  defp apply_event(event, payload) do
    suspended = event.routing_key == @suspended

    case Suspension.apply_event(event.user_id, suspended, event.version) do
      {:ok, :applied} ->
        if suspended, do: disconnect_sockets(event.user_id)
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

  # Closes the sockets of every channel of the suspended server in all the
  # instances (`Sockets.close_channels/2` goes through the broadcast fanout, like
  # `servers.server_deleted` does). If it fails the state is already stored, so the
  # next join or message is refused anyway; it is logged and the event is acked.
  defp close_server_sockets(server_id) do
    with {:ok, channel_ids} <- Repo.impl().list_channel_ids(server_id),
         :ok <- Sockets.close_channels(channel_ids, "server_suspended") do
      :ok
    else
      {:error, reason} ->
        Logger.warning("admin_events_consumer_close_sockets_failed",
          server_id: server_id,
          reason: Log.reason(reason)
        )
    end
  end

  # Reaches every member wherever they are (not only in an open channel), so their
  # client grays the server out or brings it back without reloading. Like the
  # socket cut, a failure is only logged: the state is stored and `GET /v1/servers`
  # says `suspended` on the next load.
  defp notify_members(server_id, suspended) do
    event = if suspended, do: "server_suspended", else: "server_reactivated"
    payload = %{"server_id" => server_id}

    with {:ok, members} <- Repo.impl().list_members(server_id),
         :ok <-
           Broadcaster.publish_many(
             for(%{"user_id" => user_id} <- members, do: {"user:" <> user_id, event, payload})
           ) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("admin_events_consumer_notify_members_failed",
          server_id: server_id,
          reason: Log.reason(reason)
        )
    end
  end

  # Cuts every open socket of the user in all the instances: the event goes through
  # the broadcast fanout and each instance runs `Endpoint.broadcast!` locally, which
  # Phoenix turns into the close of the sockets whose `id/1` matches the topic. If it
  # is lost the socket is still stopped by the check in `handle_in` and in `Chat`.
  defp disconnect_sockets(user_id) do
    case EventPublisher.publish_event(
           Messaging.UUID.generate(),
           "user_socket:" <> user_id,
           "disconnect",
           %{}
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("admin_events_consumer_disconnect_failed",
          user_id: user_id,
          reason: Log.reason(reason)
        )
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
         :ok <- DeadLetter.declare(chan, queue),
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
