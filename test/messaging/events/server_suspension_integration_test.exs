rabbitmq_url = System.get_env("RABBITMQ_URL")
mongo_url = System.get_env("MONGO_URL")

if rabbitmq_url && mongo_url do
  defmodule Messaging.Events.ServerSuspensionIntegrationTest do
    @moduledoc """
    From the signed `admin.server_suspended` / `admin.server_reactivated` events to
    the state in Mongo, the refusal in `Chat` and the close of the sockets of the
    channels of the server, with real RabbitMQ and Mongo. The consumer uses its own
    queue, so nothing here competes with a real instance.
    """
    use ExUnit.Case, async: false

    alias Messaging.Chat
    alias Messaging.Chat.ChannelCache
    alias Messaging.Chat.Repo.Mongo, as: Repo
    alias Messaging.Events.{AdminEventsConsumer, BroadcastConsumer, BroadcastPublisher}
    alias Messaging.ServerSuspension
    alias Messaging.Suspension.Signature

    @secret "integration-secret"
    @suspended "admin.server_suspended"
    @reactivated "admin.server_reactivated"
    @deletion_requested "admin.server_deletion_requested"

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
         url: url, queue: "messaging.admin_events.server-test-#{suffix}", secret: @secret}
      )

      assert wait_until(fn ->
               match?(%{chan: %AMQP.Channel{}}, :sys.get_state(AdminEventsConsumer)) and
                 match?(%{chan: %AMQP.Channel{}}, :sys.get_state(BroadcastConsumer)) and
                 match?(%{chan: %AMQP.Channel{}}, :sys.get_state(BroadcastPublisher))
             end)

      {:ok, conn} = AMQP.Connection.open(url)
      {:ok, chan} = AMQP.Channel.open(conn)
      :ok = AMQP.Exchange.declare(chan, "discordia.events", :topic, durable: true)

      on_exit(fn ->
        try do
          AMQP.Connection.close(conn)
        catch
          :exit, _ -> :ok
        end
      end)

      server = Messaging.UUID.generate()
      channels = for n <- 1..2, do: seed_channel(server, "#{server}-text-#{n}")
      other_server = Messaging.UUID.generate()
      other_channel = seed_channel(other_server, "#{other_server}-text-1")

      {:ok,
       chan: chan,
       server: server,
       channels: channels,
       other_server: other_server,
       other_channel: other_channel}
    end

    test "suspending a server stores it, closes the sockets of all its channels and blocks them",
         %{chan: chan, server: server, channels: channels, other_channel: other_channel} do
      for id <- [other_channel | channels], do: MessagingWeb.Endpoint.subscribe("channel:" <> id)

      assert {:ok, %ChannelCache{}} = Chat.channel_exists?(hd(channels))

      publish_admin(chan, @suspended, event(@suspended, server, 1))

      for id <- channels do
        assert_receive %Phoenix.Socket.Broadcast{
                         topic: "channel:" <> ^id,
                         event: "access_revoked",
                         payload: %{"reason" => "server_suspended", "user_id" => nil}
                       },
                       5_000
      end

      assert wait_until(fn -> ServerSuspension.suspended?(server) == {:ok, true} end)

      for id <- channels do
        assert {:error, :server_suspended} = Chat.channel_exists?(id)
      end

      # Another server is not touched, and neither are its sockets.
      refute_receive %Phoenix.Socket.Broadcast{topic: "channel:" <> ^other_channel}, 300
      assert {:ok, %ChannelCache{}} = Chat.channel_exists?(other_channel)
    end

    test "the channels are read again after the reactivation, with no socket cut",
         %{chan: chan, server: server, channels: [channel | _]} do
      publish_admin(chan, @suspended, event(@suspended, server, 1))
      assert wait_until(fn -> Chat.channel_exists?(channel) == {:error, :server_suspended} end)

      MessagingWeb.Endpoint.subscribe("channel:" <> channel)
      publish_admin(chan, @reactivated, event(@reactivated, server, 2))

      assert wait_until(fn -> match?({:ok, %ChannelCache{}}, Chat.channel_exists?(channel)) end)
      refute_receive %Phoenix.Socket.Broadcast{}, 300
    end

    test "an older version arriving late changes nothing and cuts nothing",
         %{chan: chan, server: server, channels: [channel | _]} do
      publish_admin(chan, @reactivated, event(@reactivated, server, 5))
      assert wait_until(fn -> ServerSuspension.suspended?(server) == {:ok, false} end)

      MessagingWeb.Endpoint.subscribe("channel:" <> channel)
      stale = event(@suspended, server, 4)
      publish_admin(chan, @suspended, stale)

      assert wait_until(fn ->
               match?(
                 %{"status" => "ignored_stale"},
                 Mongo.find_one(Messaging.Mongo, "consumed_events", %{"_id" => stale.event_id})
               )
             end)

      assert ServerSuspension.suspended?(server) == {:ok, false}
      refute_receive %Phoenix.Socket.Broadcast{}, 300
    end

    test "an event that does not verify changes nothing and is audited",
         %{chan: chan, server: server, channels: [channel | _]} do
      MessagingWeb.Endpoint.subscribe("channel:" <> channel)
      forged = %{event(@suspended, server, 1) | signature: String.duplicate("0", 64)}
      other_secret = event(@suspended, server, 2, "another-secret")

      publish_admin(chan, @suspended, forged)
      publish_admin(chan, @suspended, other_secret)

      for evt <- [forged, other_secret] do
        assert wait_until(fn ->
                 match?(
                   %{"status" => "discarded_invalid_signature"},
                   Mongo.find_one(Messaging.Mongo, "consumed_events", %{"_id" => evt.event_id})
                 )
               end)
      end

      assert ServerSuspension.suspended?(server) == {:ok, false}
      assert {:ok, %ChannelCache{}} = Chat.channel_exists?(channel)
      refute_receive %Phoenix.Socket.Broadcast{}, 300
    end

    test "a suspension of a server that has no channels is stored", %{chan: chan} do
      empty = Messaging.UUID.generate()

      publish_admin(chan, @suspended, event(@suspended, empty, 1))

      assert wait_until(fn -> ServerSuspension.suspended?(empty) == {:ok, true} end)
    end

    test "the deletion request is not bound to the queue, so it changes nothing",
         %{chan: chan, server: server, channels: [channel | _]} do
      MessagingWeb.Endpoint.subscribe("channel:" <> channel)
      publish_admin(chan, @deletion_requested, event(@deletion_requested, server, 1))

      refute_receive %Phoenix.Socket.Broadcast{}, 500
      assert ServerSuspension.suspended?(server) == {:ok, false}
      assert {:ok, %ChannelCache{}} = Chat.channel_exists?(channel)
    end

    defp seed_channel(server_id, channel_id) do
      :ok =
        Chat.upsert_channel(%ChannelCache{
          channel_id: channel_id,
          server_id: server_id,
          name: "general",
          kind: "text"
        })

      channel_id
    end

    defp event(routing_key, server_id, version, secret \\ @secret) do
      base = %{
        routing_key: routing_key,
        event_id: Messaging.UUID.generate(),
        server_id: server_id,
        version: version,
        occurred_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      Map.put(base, :signature, Signature.sign(base, secret))
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
  defmodule Messaging.Events.ServerSuspensionIntegrationTest do
    use ExUnit.Case

    test "skipped: set RABBITMQ_URL and MONGO_URL to run this against real services" do
      IO.puts(
        "\nSkipping server suspension integration test: RABBITMQ_URL and MONGO_URL not set.\n"
      )
    end
  end
end
