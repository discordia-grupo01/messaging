rabbitmq_url = System.get_env("RABBITMQ_URL")

if rabbitmq_url do
  defmodule Messaging.Events.BroadcastTest do
    use ExUnit.Case, async: false

    alias Messaging.Events.{BroadcastConsumer, BroadcastPublisher}

    setup do
      rabbitmq_url = System.fetch_env!("RABBITMQ_URL")
      start_supervised!({BroadcastPublisher, url: rabbitmq_url})
      start_supervised!({BroadcastConsumer, url: rabbitmq_url})
      Process.sleep(300)
      :ok
    end

    test "a message published to the fanout is delivered to the channel's local PubSub topic" do
      channel_id = "chan-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Messaging.PubSub, "channel:" <> channel_id)

      payload = %{
        "id" => Messaging.UUID.generate(),
        "channel_id" => channel_id,
        "server_id" => "srv-1",
        "user_id" => "user-1",
        "content" => "hola desde otra instancia",
        "inserted_at" => DateTime.to_iso8601(DateTime.utc_now())
      }

      assert :ok =
               BroadcastPublisher.publish_event(
                 Messaging.UUID.generate(),
                 "channel:" <> channel_id,
                 "new_message",
                 payload
               )

      assert_receive %Phoenix.Socket.Broadcast{event: "new_message", payload: ^payload}, 5_000
    end

    test "an edit is delivered as message_updated with the full message" do
      channel_id = "chan-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Messaging.PubSub, "channel:" <> channel_id)

      payload = %{
        "id" => Messaging.UUID.generate(),
        "channel_id" => channel_id,
        "content" => "corregido",
        "edited" => true,
        "edited_at" => DateTime.to_iso8601(DateTime.utc_now())
      }

      assert :ok =
               BroadcastPublisher.publish_event(
                 Messaging.UUID.generate(),
                 "channel:" <> channel_id,
                 "message_updated",
                 payload
               )

      assert_receive %Phoenix.Socket.Broadcast{event: "message_updated", payload: ^payload},
                     5_000
    end

    test "a deletion is delivered as message_deleted" do
      channel_id = "chan-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Messaging.PubSub, "channel:" <> channel_id)

      payload = %{
        "id" => Messaging.UUID.generate(),
        "channel_id" => channel_id,
        "server_id" => "srv-1",
        "deleted_at" => DateTime.to_iso8601(DateTime.utc_now())
      }

      assert :ok =
               BroadcastPublisher.publish_event(
                 Messaging.UUID.generate(),
                 "channel:" <> channel_id,
                 "message_deleted",
                 payload
               )

      assert_receive %Phoenix.Socket.Broadcast{event: "message_deleted", payload: ^payload},
                     5_000
    end

    test "a notification addressed to a user topic reaches only that user's local topic" do
      user_id = "user-#{System.unique_integer([:positive])}"
      other = "user-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Messaging.PubSub, "user:" <> user_id)
      Phoenix.PubSub.subscribe(Messaging.PubSub, "user:" <> other)

      payload = %{
        "conversation_id" => "conv-1",
        "participants" => [user_id, "x"],
        "message" => %{}
      }

      assert :ok =
               BroadcastPublisher.publish_event(
                 Messaging.UUID.generate(),
                 "user:" <> user_id,
                 "new_dm",
                 payload
               )

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: "user:" <> ^user_id,
                       event: "new_dm",
                       payload: ^payload
                     },
                     5_000

      refute_receive %Phoenix.Socket.Broadcast{topic: "user:" <> ^other}, 300
    end

    test "a domain event goes to discordia.events with its routing key and never to the instance fanout" do
      Phoenix.PubSub.subscribe(Messaging.PubSub, "domain")
      {:ok, conn} = AMQP.Connection.open(System.fetch_env!("RABBITMQ_URL"))
      {:ok, chan} = AMQP.Channel.open(conn)
      :ok = AMQP.Exchange.declare(chan, "discordia.events", :topic, durable: true)
      {:ok, %{queue: queue}} = AMQP.Queue.declare(chan, "", exclusive: true, auto_delete: true)

      :ok =
        AMQP.Queue.bind(chan, queue, "discordia.events", routing_key: "messaging.message_created")

      id = Messaging.UUID.generate()

      payload = %{
        "occurred_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "server_id" => "srv-1",
        "channel_id" => "chan-1",
        "message_id" => Messaging.UUID.generate(),
        "author_id" => "user-1",
        "mentioned_user_ids" => ["user-2"]
      }

      assert :ok =
               BroadcastPublisher.publish_event(
                 id,
                 "domain",
                 "messaging.message_created",
                 payload
               )

      assert {body, meta} = get_message(chan, queue, 50)
      assert Jason.decode!(body) == Map.put(payload, "event_id", id)
      assert meta.routing_key == "messaging.message_created"
      assert meta.message_id == id
      assert meta.content_type == "application/json"
      refute_receive %Phoenix.Socket.Broadcast{}, 500

      AMQP.Connection.close(conn)
    end

    defp get_message(_chan, _queue, 0), do: nil

    defp get_message(chan, queue, attempts) do
      case AMQP.Basic.get(chan, queue, no_ack: true) do
        {:ok, body, meta} ->
          {body, meta}

        {:empty, _meta} ->
          Process.sleep(100)
          get_message(chan, queue, attempts - 1)
      end
    end

    test "a mention published by any instance reaches the mentioned user's local topic" do
      user_id = "user-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Messaging.PubSub, "user:" <> user_id)

      payload = %{
        "server_id" => "srv-1",
        "channel_id" => "chan-1",
        "message" => %{"id" => "msg-1", "content" => "<@#{user_id}> hola"}
      }

      assert :ok =
               BroadcastPublisher.publish_event(
                 Messaging.UUID.generate(),
                 "user:" <> user_id,
                 "mention",
                 payload
               )

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: "user:" <> ^user_id,
                       event: "mention",
                       payload: ^payload
                     },
                     5_000
    end

    test "a disconnect for the sockets of a user crosses instances through the fanout" do
      user_id = "user-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Messaging.PubSub, "user_socket:" <> user_id)

      assert :ok =
               BroadcastPublisher.publish_event(
                 Messaging.UUID.generate(),
                 "user_socket:" <> user_id,
                 "disconnect",
                 %{}
               )

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: "user_socket:" <> ^user_id,
                       event: "disconnect"
                     },
                     5_000
    end

    test "a presence change reaches whoever looks at the server, from any instance" do
      server_id = "srv-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Messaging.PubSub, "presence:" <> server_id)
      payload = %{"user_id" => "user-1", "status" => "idle", "version" => 3}

      assert :ok =
               BroadcastPublisher.publish_event(
                 Messaging.UUID.generate(),
                 "presence:" <> server_id,
                 "presence_updated",
                 payload
               )

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: "presence:" <> ^server_id,
                       event: "presence_updated",
                       payload: ^payload
                     },
                     5_000
    end

    test "the status picked by hand reaches every session of the user" do
      user_id = "user-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Messaging.PubSub, "user:" <> user_id)
      payload = %{"status" => "dnd", "version" => 4}

      assert :ok =
               BroadcastPublisher.publish_event(
                 Messaging.UUID.generate(),
                 "user:" <> user_id,
                 "own_status_updated",
                 payload
               )

      assert_receive %Phoenix.Socket.Broadcast{event: "own_status_updated", payload: ^payload},
                     5_000
    end

    test "a topic outside channel: and user: is dropped" do
      Phoenix.PubSub.subscribe(Messaging.PubSub, "admin:all")

      {:ok, conn} = AMQP.Connection.open(System.fetch_env!("RABBITMQ_URL"))
      {:ok, chan} = AMQP.Channel.open(conn)

      body =
        Jason.encode!(%{"topic" => "admin:all", "event" => "new_dm", "payload" => %{"x" => 1}})

      :ok = AMQP.Basic.publish(chan, "messaging.broadcast", "", body)

      refute_receive %Phoenix.Socket.Broadcast{}, 700
      AMQP.Connection.close(conn)
    end

    test "an access_revoked notice crosses instances through the fanout" do
      channel_id = "chan-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Messaging.PubSub, "channel:" <> channel_id)

      payload = %{"channel_id" => channel_id, "reason" => "member_left", "user_id" => "user-1"}

      assert :ok =
               BroadcastPublisher.publish_event(
                 Messaging.UUID.generate(),
                 "channel:" <> channel_id,
                 "access_revoked",
                 payload
               )

      assert_receive %Phoenix.Socket.Broadcast{event: "access_revoked", payload: ^payload}, 5_000
    end

    test "events published while an instance was away are waiting for it when it comes back" do
      stop_supervised!(BroadcastConsumer)
      Process.sleep(200)

      channel_id = "chan-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Messaging.PubSub, "channel:" <> channel_id)

      payload = %{
        "id" => Messaging.UUID.generate(),
        "channel_id" => channel_id,
        "content" => "mientras no estabas"
      }

      queue = "messaging.broadcast.test-#{System.unique_integer([:positive])}"

      start_supervised!({BroadcastConsumer, url: System.fetch_env!("RABBITMQ_URL"), queue: queue},
        id: :first
      )

      Process.sleep(300)
      stop_supervised!(:first)
      Process.sleep(200)

      assert :ok =
               BroadcastPublisher.publish_event(
                 Messaging.UUID.generate(),
                 "channel:" <> channel_id,
                 "new_message",
                 payload
               )

      refute_receive %Phoenix.Socket.Broadcast{}, 300

      start_supervised!({BroadcastConsumer, url: System.fetch_env!("RABBITMQ_URL"), queue: queue},
        id: :second
      )

      assert_receive %Phoenix.Socket.Broadcast{event: "new_message", payload: ^payload}, 5_000
    end

    test "the publisher waits for the broker to confirm and tags the message with the event id" do
      {:ok, conn} = AMQP.Connection.open(System.fetch_env!("RABBITMQ_URL"))
      {:ok, chan} = AMQP.Channel.open(conn)
      {:ok, %{queue: queue}} = AMQP.Queue.declare(chan, "", exclusive: true, auto_delete: true)
      :ok = AMQP.Queue.bind(chan, queue, "messaging.broadcast")
      {:ok, _tag} = AMQP.Basic.consume(chan, queue, nil, no_ack: true)

      channel_id = "chan-#{System.unique_integer([:positive])}"
      event_id = Messaging.UUID.generate()

      assert :ok =
               BroadcastPublisher.publish_event(
                 event_id,
                 "channel:" <> channel_id,
                 "new_message",
                 %{
                   "channel_id" => channel_id
                 }
               )

      assert_receive {:basic_deliver, body, %{message_id: ^event_id}}, 5_000
      assert %{"event_id" => ^event_id, "event" => "new_message"} = Jason.decode!(body)
      AMQP.Connection.close(conn)
    end

    test "a bare message from an older publisher is still delivered as new_message" do
      channel_id = "chan-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Messaging.PubSub, "channel:" <> channel_id)
      message = %{"id" => "old-1", "channel_id" => channel_id, "content" => "legacy"}

      {:ok, conn} = AMQP.Connection.open(System.fetch_env!("RABBITMQ_URL"))
      {:ok, chan} = AMQP.Channel.open(conn)
      :ok = AMQP.Basic.publish(chan, "messaging.broadcast", "", Jason.encode!(message))

      assert_receive %Phoenix.Socket.Broadcast{event: "new_message", payload: ^message}, 5_000
      AMQP.Connection.close(conn)
    end

    test "an unknown event or a malformed body is dropped without breaking the consumer" do
      channel_id = "chan-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Messaging.PubSub, "channel:" <> channel_id)
      consumer = Process.whereis(BroadcastConsumer)

      {:ok, conn} = AMQP.Connection.open(System.fetch_env!("RABBITMQ_URL"))
      {:ok, chan} = AMQP.Channel.open(conn)

      for body <- [
            Jason.encode!(%{
              "event" => "drop_database",
              "payload" => %{"channel_id" => channel_id}
            }),
            Jason.encode!(%{"unrelated" => true}),
            "not json at all"
          ] do
        :ok = AMQP.Basic.publish(chan, "messaging.broadcast", "", body)
      end

      refute_receive %Phoenix.Socket.Broadcast{}, 700
      assert Process.alive?(consumer)
      assert Process.whereis(BroadcastConsumer) == consumer
      AMQP.Connection.close(conn)
    end
  end
else
  defmodule Messaging.Events.BroadcastTest do
    use ExUnit.Case

    test "skipped: set RABBITMQ_URL to run this against a real broker" do
      IO.puts("\nSkipping Broadcast integration test: RABBITMQ_URL not set.\n")
    end
  end
end
