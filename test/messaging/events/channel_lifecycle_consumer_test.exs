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

    test "consuming servers.channel_deleted evicts the channel and its messages", %{
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

      {:ok, _} =
        Mongo.insert_one(Messaging.Mongo, "messages", %{
          "_id" => Messaging.UUID.generate(),
          "channel_id" => channel_id,
          "server_id" => server_id,
          "user_id" => "user-1",
          "content" => "hola",
          "inserted_at" => DateTime.utc_now()
        })

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

      assert Mongo.count_documents!(Messaging.Mongo, "messages", %{"channel_id" => channel_id}) ==
               0
    end

    test "consuming servers.server_deleted purges the server's messages and channels", %{
      chan: chan
    } do
      server_id = "srv-#{Messaging.UUID.generate()}"
      channel_id = "chan-#{Messaging.UUID.generate()}"
      other_server_id = "srv-#{Messaging.UUID.generate()}"
      other_channel_id = "chan-#{Messaging.UUID.generate()}"
      event_id = Messaging.UUID.generate()

      for {srv, ch} <- [{server_id, channel_id}, {other_server_id, other_channel_id}] do
        :ok =
          Chat.upsert_channel(%Messaging.Chat.ChannelCache{
            channel_id: ch,
            server_id: srv,
            name: "general",
            kind: "text"
          })

        {:ok, _doc} =
          Messaging.Chat.Repo.Mongo.insert_message(%{
            "_id" => Messaging.UUID.generate_v7(),
            "channel_id" => ch,
            "server_id" => srv,
            "user_id" => "user-1",
            "content" => "hola",
            "inserted_at" => DateTime.utc_now()
          })
      end

      payload =
        Jason.encode!(%{
          "event_id" => event_id,
          "occurred_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "server_id" => server_id,
          "channel_ids" => [channel_id]
        })

      :ok =
        AMQP.Basic.publish(chan, @exchange, "servers.server_deleted", payload, persistent: true)

      assert wait_until(fn ->
               match?({:error, :channel_not_found}, Chat.channel_exists?(channel_id))
             end)

      assert {:ok, [], nil} = Chat.list_messages(channel_id)
      assert {:ok, _channel} = Chat.channel_exists?(other_channel_id)
      assert {:ok, [_message], nil} = Chat.list_messages(other_channel_id)

      assert wait_until(fn ->
               match?(%{"status" => "processed"}, consumed_event(event_id))
             end)
    end

    test "a server_deleted with a malformed channel list is discarded and changes nothing", %{
      chan: chan
    } do
      event_id = Messaging.UUID.generate()

      payload =
        Jason.encode!(%{
          "event_id" => event_id,
          "occurred_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "server_id" => "srv-x",
          "channel_ids" => [%{"$ne" => "x"}]
        })

      :ok =
        AMQP.Basic.publish(chan, @exchange, "servers.server_deleted", payload, persistent: true)

      assert wait_until(fn ->
               match?(%{"status" => "discarded_invalid_payload"}, consumed_event(event_id))
             end)
    end

    test "consuming servers.member_left drops that member's mentions in that server only", %{
      chan: chan
    } do
      server_id = "srv-#{Messaging.UUID.generate()}"
      other_server_id = "srv-#{Messaging.UUID.generate()}"
      user_id = "user-#{System.unique_integer([:positive])}"
      event_id = Messaging.UUID.generate()

      for {id, sid} <- [{"m1", server_id}, {"m2", server_id}, {"m3", other_server_id}] do
        {:ok, _} =
          Mongo.insert_one(Messaging.Mongo, "mentions", %{
            "_id" => "#{id}-#{event_id}:#{user_id}",
            "user_id" => user_id,
            "message_id" => "#{id}-#{event_id}",
            "channel_id" => "chan-1",
            "server_id" => sid,
            "author_id" => "author-1",
            "inserted_at" => DateTime.utc_now(),
            "read_at" => nil
          })
      end

      payload =
        Jason.encode!(%{
          "event_id" => event_id,
          "occurred_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "server_id" => server_id,
          "user_id" => user_id
        })

      :ok = AMQP.Basic.publish(chan, @exchange, "servers.member_left", payload, persistent: true)

      assert wait_until(fn ->
               match?(%{"status" => "processed"}, consumed_event(event_id))
             end)

      assert Mongo.count_documents!(Messaging.Mongo, "mentions", %{
               "user_id" => user_id,
               "server_id" => server_id
             }) == 0

      assert Mongo.count_documents!(Messaging.Mongo, "mentions", %{
               "user_id" => user_id,
               "server_id" => other_server_id
             }) == 1
    end

    describe "closing sockets and ordering" do
      defp seed_channels(server_id, count) do
        for n <- 1..count do
          id = "chan-#{n}-#{Messaging.UUID.generate()}"

          :ok =
            Chat.upsert_channel(%Messaging.Chat.ChannelCache{
              channel_id: id,
              server_id: server_id,
              name: "n#{n}",
              kind: "text"
            })

          MessagingWeb.Endpoint.subscribe("channel:" <> id)
          id
        end
      end

      defp publish(chan, key, fields, at \\ DateTime.utc_now()) do
        event_id = Messaging.UUID.generate()

        body =
          Map.merge(
            %{"event_id" => event_id, "occurred_at" => DateTime.to_iso8601(at)},
            fields
          )

        :ok = AMQP.Basic.publish(chan, @exchange, key, Jason.encode!(body), persistent: true)
        event_id
      end

      defp status(event_id), do: (consumed_event(event_id) || %{})["status"]

      test "a member leaving, kicked or banned loses the open channels of that server, and only theirs",
           %{chan: chan} do
        server = "srv-#{Messaging.UUID.generate()}"
        [first, second] = seed_channels(server, 2)
        user = "user-#{Messaging.UUID.generate()}"

        event_id =
          publish(chan, "servers.member_left", %{"server_id" => server, "user_id" => user})

        for id <- [first, second] do
          assert_receive %Phoenix.Socket.Broadcast{
                           topic: "channel:" <> ^id,
                           event: "access_revoked",
                           payload: %{"user_id" => ^user, "reason" => "member_left"}
                         },
                         5_000
        end

        assert wait_until(fn -> status(event_id) == "processed" end)
      end

      test "a leave that arrives after a newer join is dropped: the user is not kicked", %{
        chan: chan
      } do
        server = "srv-#{Messaging.UUID.generate()}"
        [channel] = seed_channels(server, 1)
        user = "user-#{Messaging.UUID.generate()}"
        now = DateTime.utc_now()

        joined =
          publish(chan, "servers.member_joined", %{"server_id" => server, "user_id" => user}, now)

        assert wait_until(fn -> status(joined) == "processed" end)

        stale =
          publish(
            chan,
            "servers.member_left",
            %{"server_id" => server, "user_id" => user},
            DateTime.add(now, -60, :second)
          )

        assert wait_until(fn -> status(stale) == "ignored_stale" end)
        refute_receive %Phoenix.Socket.Broadcast{topic: "channel:" <> ^channel}, 200
      end

      test "a leave, then a re-join, then a late duplicate of the leave: still not kicked again",
           %{
             chan: chan
           } do
        server = "srv-#{Messaging.UUID.generate()}"
        [channel] = seed_channels(server, 1)
        user = "user-#{Messaging.UUID.generate()}"
        now = DateTime.utc_now()
        fields = %{"server_id" => server, "user_id" => user}

        left = publish(chan, "servers.member_left", fields, now)
        assert_receive %Phoenix.Socket.Broadcast{event: "access_revoked"}, 5_000
        assert wait_until(fn -> status(left) == "processed" end)

        joined = publish(chan, "servers.member_joined", fields, DateTime.add(now, 30, :second))
        assert wait_until(fn -> status(joined) == "processed" end)

        duplicate = publish(chan, "servers.member_left", fields, now)
        assert wait_until(fn -> status(duplicate) == "ignored_stale" end)
        refute_receive %Phoenix.Socket.Broadcast{topic: "channel:" <> ^channel}, 200
      end

      test "a permissions change closes that channel for the listed users only, every time it arrives",
           %{chan: chan} do
        server = "srv-#{Messaging.UUID.generate()}"
        [channel, other] = seed_channels(server, 2)
        users = ["user-#{Messaging.UUID.generate()}", "user-#{Messaging.UUID.generate()}"]
        fields = %{"server_id" => server, "channel_id" => channel, "user_ids" => users}

        for _delivery <- 1..2 do
          event_id = publish(chan, "servers.channel_access_revoked", fields)

          for user <- users do
            assert_receive %Phoenix.Socket.Broadcast{
                             topic: "channel:" <> ^channel,
                             event: "access_revoked",
                             payload: %{"user_id" => ^user, "reason" => "permissions_changed"}
                           },
                           5_000
          end

          assert wait_until(fn -> status(event_id) == "processed" end)
        end

        refute_receive %Phoenix.Socket.Broadcast{topic: "channel:" <> ^other}, 200
      end

      test "a deleted channel closes its sockets, whoever they belong to", %{chan: chan} do
        server = "srv-#{Messaging.UUID.generate()}"
        [channel] = seed_channels(server, 1)

        event_id =
          publish(chan, "servers.channel_deleted", %{
            "server_id" => server,
            "channel_id" => channel
          })

        assert_receive %Phoenix.Socket.Broadcast{
                         topic: "channel:" <> ^channel,
                         event: "access_revoked",
                         payload: %{"user_id" => nil, "reason" => "channel_deleted"}
                       },
                       5_000

        assert wait_until(fn -> status(event_id) == "processed" end)
        assert {:error, :channel_not_found} = Chat.channel_exists?(channel)
      end

      test "a deleted server closes every channel it had, even those only the cache knew", %{
        chan: chan
      } do
        server = "srv-#{Messaging.UUID.generate()}"
        [known, cached_only] = seed_channels(server, 2)

        publish(chan, "servers.server_deleted", %{"server_id" => server, "channel_ids" => [known]})

        for id <- [known, cached_only] do
          assert_receive %Phoenix.Socket.Broadcast{
                           topic: "channel:" <> ^id,
                           event: "access_revoked",
                           payload: %{"reason" => "server_deleted"}
                         },
                         5_000
        end
      end

      test "a channel_created that arrives after its channel_deleted is dropped", %{chan: chan} do
        server = "srv-#{Messaging.UUID.generate()}"
        channel = "chan-#{Messaging.UUID.generate()}"
        now = DateTime.utc_now()

        deleted =
          publish(
            chan,
            "servers.channel_deleted",
            %{"server_id" => server, "channel_id" => channel},
            now
          )

        assert wait_until(fn -> status(deleted) == "processed" end)

        late =
          publish(
            chan,
            "servers.channel_created",
            %{"server_id" => server, "channel_id" => channel, "name" => "x", "kind" => "text"},
            DateTime.add(now, -30, :second)
          )

        assert wait_until(fn -> status(late) == "ignored_stale" end)
        assert {:error, :channel_not_found} = Chat.channel_exists?(channel)
      end

      test "a channel_created for a server that was already deleted is dropped", %{chan: chan} do
        server = "srv-#{Messaging.UUID.generate()}"
        channel = "chan-#{Messaging.UUID.generate()}"

        deleted =
          publish(chan, "servers.server_deleted", %{"server_id" => server, "channel_ids" => []})

        assert wait_until(fn -> status(deleted) == "processed" end)

        late =
          publish(chan, "servers.channel_created", %{
            "server_id" => server,
            "channel_id" => channel,
            "name" => "x",
            "kind" => "text"
          })

        assert wait_until(fn -> status(late) == "ignored_stale" end)
        assert {:error, :channel_not_found} = Chat.channel_exists?(channel)
      end

      test "if the sockets cannot be told, the event is not lost: it is retried until it works",
           %{
             chan: chan
           } do
        previous = Application.get_env(:messaging, :broadcaster)
        Application.put_env(:messaging, :broadcaster, Messaging.FailingBroadcaster)
        Application.put_env(:messaging, :event_retry_delay_ms, 50)

        on_exit(fn ->
          Application.put_env(:messaging, :broadcaster, previous)
          Application.delete_env(:messaging, :event_retry_delay_ms)
        end)

        server = "srv-#{Messaging.UUID.generate()}"
        [channel] = seed_channels(server, 1)
        user = "user-#{Messaging.UUID.generate()}"

        event_id =
          publish(chan, "servers.member_left", %{"server_id" => server, "user_id" => user})

        Process.sleep(400)
        assert status(event_id) == nil
        refute_received %Phoenix.Socket.Broadcast{}

        Application.put_env(:messaging, :broadcaster, Messaging.Events.LocalBroadcaster)

        assert_receive %Phoenix.Socket.Broadcast{
                         topic: "channel:" <> ^channel,
                         event: "access_revoked",
                         payload: %{"user_id" => ^user}
                       },
                       5_000

        assert wait_until(fn -> status(event_id) == "processed" end)
      end
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
