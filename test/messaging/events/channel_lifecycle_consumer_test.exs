rabbitmq_url = System.get_env("RABBITMQ_URL")
mongo_url = System.get_env("MONGO_URL")

if rabbitmq_url && mongo_url do
  defmodule Messaging.Events.ChannelLifecycleConsumerTest do
    use ExUnit.Case, async: false

    alias Messaging.Chat

    @exchange "discordia.events"

    setup do
      previous_repo = Application.get_env(:messaging, :chat_repo)
      Application.put_env(:messaging, :chat_repo, Messaging.Chat.Repo.Mongo)
      on_exit(fn -> Application.put_env(:messaging, :chat_repo, previous_repo) end)

      rabbitmq_url = System.fetch_env!("RABBITMQ_URL")
      queue = "messaging.channel_lifecycle.test-#{System.unique_integer([:positive])}"

      start_supervised!(
        {Messaging.Events.ChannelLifecycleConsumer, url: rabbitmq_url, queue: queue}
      )

      assert wait_until(fn ->
               match?(
                 %{chan: %AMQP.Channel{}},
                 :sys.get_state(Messaging.Events.ChannelLifecycleConsumer)
               )
             end)

      {:ok, conn} = AMQP.Connection.open(rabbitmq_url)
      {:ok, chan} = AMQP.Channel.open(conn)
      :ok = AMQP.Exchange.declare(chan, @exchange, :topic, durable: true)

      on_exit(fn ->
        try do
          AMQP.Connection.close(conn)
        catch
          :exit, _ -> :ok
        end
      end)

      {:ok, chan: chan}
    end

    test "consuming servers.channel_created upserts the channel into the local read model", %{
      chan: chan
    } do
      channel_id = "chan-#{System.unique_integer([:positive])}"
      server_id = "srv-#{System.unique_integer([:positive])}"
      event_id = Messaging.UUID.generate()

      payload =
        Jason.encode!(%{
          "event_id" => event_id,
          "occurred_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "server_id" => server_id,
          "channel_id" => channel_id,
          "name" => "general",
          "kind" => "text"
        })

      :ok =
        AMQP.Basic.publish(chan, @exchange, "servers.channel_created", payload, persistent: true)

      assert wait_until(fn ->
               match?(
                 {:ok, %Messaging.Chat.ChannelCache{channel_id: ^channel_id}},
                 Chat.channel_exists?(channel_id)
               )
             end)

      assert wait_until(fn ->
               match?(%{"status" => "processed"}, consumed_event(event_id))
             end)
    end

    test "an unparseable payload is recorded in the audit trail as discarded", %{chan: chan} do
      raw_body = "not json #{System.unique_integer([:positive])}"

      :ok =
        AMQP.Basic.publish(chan, @exchange, "servers.channel_created", raw_body, persistent: true)

      assert wait_until(fn ->
               match?(
                 %{"status" => "discarded_malformed_payload", "event_id" => nil},
                 Mongo.find_one(Messaging.Mongo, "consumed_events", %{"raw_body" => raw_body})
               )
             end)
    end

    test "consuming servers.channel_deleted evicts the channel from the local read model", %{
      chan: chan
    } do
      channel_id = "chan-#{System.unique_integer([:positive])}"
      server_id = "srv-#{System.unique_integer([:positive])}"

      :ok =
        Chat.upsert_channel(%Messaging.Chat.ChannelCache{
          channel_id: channel_id,
          server_id: server_id,
          name: "general",
          kind: "text"
        })

      assert {:ok, _channel} = Chat.channel_exists?(channel_id)

      payload =
        Jason.encode!(%{
          "event_id" => Messaging.UUID.generate(),
          "occurred_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "server_id" => server_id,
          "channel_id" => channel_id
        })

      :ok =
        AMQP.Basic.publish(chan, @exchange, "servers.channel_deleted", payload, persistent: true)

      assert wait_until(fn ->
               match?({:error, :channel_not_found}, Chat.channel_exists?(channel_id))
             end)
    end

    defp consumed_event(event_id),
      do: Mongo.find_one(Messaging.Mongo, "consumed_events", %{"_id" => event_id})

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
  defmodule Messaging.Events.ChannelLifecycleConsumerTest do
    use ExUnit.Case

    test "skipped: set RABBITMQ_URL and MONGO_URL to run this against real infra" do
      IO.puts(
        "\nSkipping ChannelLifecycleConsumer integration test: RABBITMQ_URL/MONGO_URL not set.\n" <>
          "Run `docker compose up -d mongo` here and start RabbitMQ from the rabbit-mq repo, then\n" <>
          "export RABBITMQ_URL=amqp://guest:guest@localhost:5672/ MONGO_URL=mongodb://localhost:27017/messaging_test\n"
      )
    end
  end
end
