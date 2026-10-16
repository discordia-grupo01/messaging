rabbitmq_url = System.get_env("RABBITMQ_URL")
mongo_url = System.get_env("MONGO_URL")

if rabbitmq_url && mongo_url do
  defmodule Messaging.Events.SuspensionDisconnectTest do
    @moduledoc """
    From the `admin.user_suspended` event to the close of the sockets of the user,
    with real RabbitMQ and Mongo. Instance A is this node (its `BroadcastConsumer`
    runs `Endpoint.broadcast!` locally); instance B is simulated with its own queue
    bound to the fanout, which is what every other instance has.
    """
    use ExUnit.Case, async: false

    alias Messaging.Chat.Repo.Mongo, as: Repo
    alias Messaging.Events.{AdminEventsConsumer, BroadcastConsumer, BroadcastPublisher}
    alias Messaging.Suspension
    alias Messaging.Suspension.Signature

    @secret "integration-secret"
    @suspended "admin.user_suspended"
    @reactivated "admin.user_reactivated"

    setup do
      previous_repo = Application.get_env(:messaging, :chat_repo)
      previous_publisher = Application.get_env(:messaging, :event_publisher)
      Application.put_env(:messaging, :chat_repo, Repo)
      Application.put_env(:messaging, :event_publisher, BroadcastPublisher)

      on_exit(fn ->
        Application.put_env(:messaging, :chat_repo, previous_repo)
        Application.put_env(:messaging, :event_publisher, previous_publisher)
      end)

      url = System.fetch_env!("RABBITMQ_URL")
      suffix = System.unique_integer([:positive])

      start_supervised!({BroadcastPublisher, url: url})
      start_supervised!({BroadcastConsumer, url: url})

      start_supervised!(
        {AdminEventsConsumer,
         url: url, queue: "messaging.admin_events.test-#{suffix}", secret: @secret}
      )

      assert wait_until(fn ->
               match?(%{chan: %AMQP.Channel{}}, :sys.get_state(AdminEventsConsumer)) and
                 match?(%{chan: %AMQP.Channel{}}, :sys.get_state(BroadcastConsumer)) and
                 match?(%{chan: %AMQP.Channel{}}, :sys.get_state(BroadcastPublisher))
             end)

      {:ok, conn} = AMQP.Connection.open(url)
      {:ok, chan} = AMQP.Channel.open(conn)
      :ok = AMQP.Exchange.declare(chan, "discordia.events", :topic, durable: true)

      instance_b = "messaging.broadcast.test-instance-b-#{suffix}"
      {:ok, _info} = AMQP.Queue.declare(chan, instance_b, auto_delete: true)
      :ok = AMQP.Queue.bind(chan, instance_b, "messaging.broadcast")
      {:ok, _tag} = AMQP.Basic.consume(chan, instance_b, nil, no_ack: true)

      on_exit(fn ->
        try do
          AMQP.Connection.close(conn)
        catch
          :exit, _ -> :ok
        end
      end)

      {:ok, chan: chan, user: Messaging.UUID.generate()}
    end

    test "suspending a user closes its open sockets in this instance and reaches the others", %{
      chan: chan,
      user: user
    } do
      topic = "user_socket:" <> user
      socket_state = open_transport(user)

      publish_admin(chan, @suspended, event(@suspended, user, 1))

      # Instance A: the own transport handler of Phoenix stops on the local broadcast.
      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"} = message,
                     5_000

      assert {:stop, {:shutdown, :disconnected}, 1001, _state} =
               Phoenix.Socket.__info__(message, socket_state)

      # Instance B: its own queue on the fanout got the same order.
      assert_receive {:basic_deliver, body, _meta}, 5_000

      assert %{"topic" => ^topic, "event" => "disconnect", "payload" => %{}} =
               Jason.decode!(body)

      assert wait_until(fn -> Suspension.suspended?(user) == {:ok, true} end)
    end

    test "an event that does not verify cuts nothing", %{chan: chan, user: user} do
      _state = open_transport(user)
      forged = %{event(@suspended, user, 1) | signature: String.duplicate("0", 64)}

      publish_admin(chan, @suspended, forged)

      assert wait_until(fn ->
               match?(
                 %{"status" => "discarded_invalid_signature"},
                 Mongo.find_one(Messaging.Mongo, "consumed_events", %{"_id" => forged.event_id})
               )
             end)

      refute_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 500
      refute_received {:basic_deliver, _body, _meta}
    end

    test "reactivating does not cut sockets and gives the capabilities back", %{
      chan: chan,
      user: user
    } do
      _state = open_transport(user)
      publish_admin(chan, @suspended, event(@suspended, user, 1))
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 5_000
      assert_receive {:basic_deliver, _body, _meta}, 5_000

      publish_admin(chan, @reactivated, event(@reactivated, user, 2))
      assert wait_until(fn -> Suspension.suspended?(user) == {:ok, false} end)

      refute_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 500
      assert :ok = Suspension.ensure_active(user)
    end

    # Subscribes this process the way the websocket transport does for a socket
    # whose `id/1` is "user_socket:<user>", and returns the state it would keep.
    defp open_transport(user) do
      socket = %Phoenix.Socket{
        id: "user_socket:" <> user,
        endpoint: MessagingWeb.Endpoint,
        handler: MessagingWeb.UserSocket
      }

      {:ok, state} = Phoenix.Socket.__init__({%{channels: %{}, channels_inverse: %{}}, socket})
      state
    end

    defp event(routing_key, user_id, version) do
      base = %{
        routing_key: routing_key,
        event_id: Messaging.UUID.generate(),
        user_id: user_id,
        version: version,
        occurred_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      Map.put(base, :signature, Signature.sign(base, @secret))
    end

    defp publish_admin(chan, routing_key, event) do
      payload =
        event
        |> Map.delete(:routing_key)
        |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
        |> Jason.encode!()

      :ok = AMQP.Basic.publish(chan, "discordia.events", routing_key, payload, persistent: true)
    end

    defp wait_until(fun, attempts \\ 50)
    defp wait_until(_fun, 0), do: false

    defp wait_until(fun, attempts) do
      if fun.() do
        true
      else
        Process.sleep(100)
        wait_until(fun, attempts - 1)
      end
    end
  end
else
  defmodule Messaging.Events.SuspensionDisconnectTest do
    use ExUnit.Case

    test "skipped: set RABBITMQ_URL and MONGO_URL to run this against real services" do
      IO.puts("\nSkipping suspension disconnect test: RABBITMQ_URL and MONGO_URL not set.\n")
    end
  end
end
