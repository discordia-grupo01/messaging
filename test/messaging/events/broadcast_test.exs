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

      assert :ok = BroadcastPublisher.publish("channel:" <> channel_id, "new_message", payload)

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
               BroadcastPublisher.publish("channel:" <> channel_id, "message_updated", payload)

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
               BroadcastPublisher.publish("channel:" <> channel_id, "message_deleted", payload)

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

      assert :ok = BroadcastPublisher.publish("user:" <> user_id, "new_dm", payload)

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: "user:" <> ^user_id,
                       event: "new_dm",
                       payload: ^payload
                     },
                     5_000

      refute_receive %Phoenix.Socket.Broadcast{topic: "user:" <> ^other}, 300
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
