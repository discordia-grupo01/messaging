mongo_url = System.get_env("MONGO_URL")

if mongo_url do
  defmodule Messaging.Events.AuditTest do
    use ExUnit.Case, async: false

    alias Messaging.Events.Audit

    test "records a processed event keyed by event_id, upserting on redelivery" do
      event_id = Messaging.UUID.generate()

      :ok =
        Audit.record(%{
          event_id: event_id,
          routing_key: "servers.channel_created",
          raw_body: "{}",
          status: :processed,
          error: nil
        })

      assert %{"status" => "processed", "attempts" => 1} = fetch(event_id)

      :ok =
        Audit.record(%{
          event_id: event_id,
          routing_key: "servers.channel_created",
          raw_body: "{}",
          status: :processed,
          error: nil
        })

      assert %{"status" => "processed", "attempts" => 2} = fetch(event_id)
    end

    test "records a discarded event with its error reason" do
      event_id = Messaging.UUID.generate()

      :ok =
        Audit.record(%{
          event_id: event_id,
          routing_key: "servers.unknown_thing",
          raw_body: "{}",
          status: :discarded_unknown_routing_key,
          error: ":unknown_routing_key"
        })

      assert %{"status" => "discarded_unknown_routing_key", "error" => ":unknown_routing_key"} =
               fetch(event_id)
    end

    test "records a malformed delivery that has no event_id under its own generated id" do
      :ok =
        Audit.record(%{
          routing_key: "servers.channel_created",
          raw_body: "not json",
          status: :discarded_malformed_payload,
          error: "invalid json"
        })

      assert %{"event_id" => nil, "status" => "discarded_malformed_payload"} =
               Mongo.find_one(Messaging.Mongo, "consumed_events", %{
                 "routing_key" => "servers.channel_created",
                 "raw_body" => "not json"
               })
    end

    defp fetch(event_id),
      do: Mongo.find_one(Messaging.Mongo, "consumed_events", %{"_id" => event_id})
  end
else
  defmodule Messaging.Events.AuditTest do
    use ExUnit.Case

    test "skipped: set MONGO_URL to run this against a real Mongo instance" do
      IO.puts(
        "\nSkipping Audit test: MONGO_URL not set.\n" <>
          "Run `docker compose up -d mongo` here, then\n" <>
          "export MONGO_URL=mongodb://localhost:27017/messaging_test\n"
      )
    end
  end
end
