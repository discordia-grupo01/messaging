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

      assert :ok = BroadcastPublisher.publish(payload)

      assert_receive %Phoenix.Socket.Broadcast{event: "new_message", payload: ^payload}, 5_000
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
