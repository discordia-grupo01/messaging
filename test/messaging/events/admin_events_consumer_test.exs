rabbitmq_url = System.get_env("RABBITMQ_URL")
mongo_url = System.get_env("MONGO_URL")

if rabbitmq_url && mongo_url do
  defmodule Messaging.Events.AdminEventsConsumerTest do
    use ExUnit.Case, async: false
    import ExUnit.CaptureLog
    import Mox

    alias Messaging.Chat.Repo.Mongo, as: Repo
    alias Messaging.Suspension
    alias Messaging.Suspension.Signature

    @exchange "discordia.events"
    @secret "integration-secret"
    @suspended "admin.user_suspended"
    @reactivated "admin.user_reactivated"

    setup :set_mox_global
    setup :verify_on_exit!

    setup do
      stub(Messaging.EventPublisherMock, :publish_event, fn _id, _topic, _event, _payload ->
        :ok
      end)

      previous_repo = Application.get_env(:messaging, :chat_repo)
      Application.put_env(:messaging, :chat_repo, Repo)
      on_exit(fn -> Application.put_env(:messaging, :chat_repo, previous_repo) end)

      rabbitmq_url = System.fetch_env!("RABBITMQ_URL")
      queue = "messaging.admin_events.test-#{System.unique_integer([:positive])}"

      start_supervised!(
        {Messaging.Events.AdminEventsConsumer, url: rabbitmq_url, queue: queue, secret: @secret}
      )

      assert wait_until(fn ->
               match?(
                 %{chan: %AMQP.Channel{}},
                 :sys.get_state(Messaging.Events.AdminEventsConsumer)
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

        delete_queue(rabbitmq_url, queue)
      end)

      {:ok, chan: chan, user: Messaging.UUID.generate(), queue: queue}
    end

    test "a signed suspension suspends the user and is audited as processed", %{
      chan: chan,
      user: user
    } do
      event = event(@suspended, user, 1)
      publish(chan, @suspended, event)

      assert wait_until(fn -> Suspension.suspended?(user) == {:ok, true} end)
      assert wait_until(fn -> match?(%{"status" => "processed"}, consumed(event.event_id)) end)
    end

    test "a suspension cuts the sockets of the user through the broadcast fanout", %{
      chan: chan,
      user: user
    } do
      test_pid = self()
      topic = "user_socket:" <> user

      expect(Messaging.EventPublisherMock, :publish_event, fn id, ^topic, "disconnect", %{} ->
        send(test_pid, {:disconnect_published, id})
        :ok
      end)

      publish(chan, @suspended, event(@suspended, user, 1))

      assert_receive {:disconnect_published, id} when is_binary(id), 5_000
    end

    test "a reactivation, a repeated event and a rejected one cut nothing", %{
      chan: chan,
      user: user
    } do
      test_pid = self()

      stub(Messaging.EventPublisherMock, :publish_event, fn _id, topic, event, _payload ->
        send(test_pid, {:published, topic, event})
        :ok
      end)

      publish(chan, @suspended, event(@suspended, user, 3))
      assert_receive {:published, _topic, "disconnect"}, 5_000

      repeated = event(@suspended, user, 3)
      reactivation = event(@reactivated, user, 4)
      forged = %{event(@suspended, user, 9) | signature: String.duplicate("0", 64)}
      publish(chan, @suspended, repeated)
      publish(chan, @reactivated, reactivation)
      publish(chan, @suspended, forged)

      for event <- [repeated, reactivation, forged] do
        assert wait_until(fn -> consumed(event.event_id) != nil end)
      end

      refute_received {:published, _topic, _event}
    end

    test "if the fanout is down the suspension still holds and the event is acknowledged", %{
      chan: chan,
      user: user
    } do
      stub(Messaging.EventPublisherMock, :publish_event, fn _id, _topic, _event, _payload ->
        {:error, :not_connected}
      end)

      event = event(@suspended, user, 1)

      log =
        capture_log(fn ->
          publish(chan, @suspended, event)

          assert wait_until(fn -> match?(%{"status" => "processed"}, consumed(event.event_id)) end)
        end)

      assert log =~ "admin_events_consumer_disconnect_failed"
      assert Suspension.suspended?(user) == {:ok, true}
    end

    test "a reactivation lifts the suspension", %{chan: chan, user: user} do
      publish(chan, @suspended, event(@suspended, user, 1))
      assert wait_until(fn -> Suspension.suspended?(user) == {:ok, true} end)

      publish(chan, @reactivated, event(@reactivated, user, 2))
      assert wait_until(fn -> Suspension.suspended?(user) == {:ok, false} end)
    end

    test "the state survives a cold cache, as it lives in Mongo", %{chan: chan, user: user} do
      publish(chan, @suspended, event(@suspended, user, 1))
      assert wait_until(fn -> Suspension.suspended?(user) == {:ok, true} end)

      Suspension.invalidate(user)
      assert Repo.suspended?(user) == true
    end

    test "a repeated event and an older version change nothing and are audited as stale", %{
      chan: chan,
      user: user
    } do
      publish(chan, @suspended, event(@suspended, user, 5))
      assert wait_until(fn -> Suspension.suspended?(user) == {:ok, true} end)

      repeated = event(@suspended, user, 5)
      older = event(@reactivated, user, 4)
      publish(chan, @suspended, repeated)
      publish(chan, @reactivated, older)

      assert wait_until(fn ->
               match?(%{"status" => "ignored_stale"}, consumed(repeated.event_id))
             end)

      assert wait_until(fn -> match?(%{"status" => "ignored_stale"}, consumed(older.event_id)) end)

      assert Suspension.suspended?(user) == {:ok, true}
    end

    test "a reactivation that arrives before the suspension it follows wins", %{
      chan: chan,
      user: user
    } do
      publish(chan, @reactivated, event(@reactivated, user, 2))
      assert wait_until(fn -> Repo.suspended?(user) == false and version(user) == 2 end)

      late = event(@suspended, user, 1)
      publish(chan, @suspended, late)

      assert wait_until(fn -> match?(%{"status" => "ignored_stale"}, consumed(late.event_id)) end)
      assert Suspension.suspended?(user) == {:ok, false}
    end

    test "an event without signature is discarded, audited and changes nothing", %{
      chan: chan,
      user: user
    } do
      event = event(@suspended, user, 1)
      publish(chan, @suspended, Map.delete(event, :signature))

      assert_discarded_invalid_signature(event, user)
    end

    test "an event with an invalid signature is discarded", %{chan: chan, user: user} do
      event = event(@suspended, user, 1)
      publish(chan, @suspended, %{event | signature: String.duplicate("0", 64)})

      assert_discarded_invalid_signature(event, user)
    end

    test "an event signed with another secret is discarded", %{chan: chan, user: user} do
      event = event(@suspended, user, 1)
      forged = %{event | signature: Signature.sign(Map.delete(event, :signature), "other-secret")}
      publish(chan, @suspended, forged)

      assert_discarded_invalid_signature(event, user)
    end

    test "a suspension signature replayed as a reactivation is discarded", %{
      chan: chan,
      user: user
    } do
      publish(chan, @suspended, event(@suspended, user, 1))
      assert wait_until(fn -> Suspension.suspended?(user) == {:ok, true} end)

      replay = event(@suspended, user, 2)
      publish(chan, @reactivated, replay)

      assert wait_until(fn ->
               match?(%{"status" => "discarded_invalid_signature"}, consumed(replay.event_id))
             end)

      assert Suspension.suspended?(user) == {:ok, true}
    end

    test "a payload with an empty user_id or a non integer version is discarded", %{chan: chan} do
      no_user = event(@suspended, "", 1)
      float_version = %{event(@suspended, "u-1", 1) | version: 1.5}
      string_version = %{event(@suspended, "u-2", 1) | version: "1"}

      publish(chan, @suspended, no_user)
      publish(chan, @suspended, float_version)
      publish(chan, @suspended, string_version)

      for event <- [no_user, float_version, string_version] do
        assert wait_until(fn ->
                 match?(%{"status" => "discarded_invalid_payload"}, consumed(event.event_id))
               end)
      end
    end

    test "a message that is not JSON is discarded", %{chan: chan} do
      raw_body = "not json #{System.unique_integer([:positive])}"
      :ok = AMQP.Basic.publish(chan, @exchange, @suspended, raw_body, persistent: true)

      assert wait_until(fn ->
               match?(
                 %{"status" => "discarded_malformed_payload", "event_id" => nil},
                 Mongo.find_one(Messaging.Mongo, "consumed_events", %{"raw_body" => raw_body})
               )
             end)
    end

    test "the consumer declares its own durable queue", %{queue: queue} do
      {:ok, conn} = AMQP.Connection.open(System.fetch_env!("RABBITMQ_URL"))
      {:ok, chan} = AMQP.Channel.open(conn)

      # Passive declare fails (closing the channel) if the queue does not exist.
      assert {:ok, %{queue: ^queue}} = AMQP.Queue.declare(chan, queue, passive: true)
      AMQP.Connection.close(conn)
    end

    defp assert_discarded_invalid_signature(event, user) do
      assert wait_until(fn ->
               match?(
                 %{"status" => "discarded_invalid_signature"},
                 consumed(event.event_id)
               )
             end)

      assert Repo.suspended?(user) == false
      assert Mongo.find_one(Messaging.Mongo, "suspended_users", %{"_id" => user}) == nil
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

    defp publish(chan, routing_key, event) do
      payload =
        event
        |> Map.delete(:routing_key)
        |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
        |> Jason.encode!()

      :ok = AMQP.Basic.publish(chan, @exchange, routing_key, payload, persistent: true)
    end

    defp version(user) do
      case Mongo.find_one(Messaging.Mongo, "suspended_users", %{"_id" => user}) do
        %{"version" => version} -> version
        _none -> nil
      end
    end

    defp consumed(event_id),
      do: Mongo.find_one(Messaging.Mongo, "consumed_events", %{"_id" => event_id})

    defp delete_queue(url, queue) do
      with {:ok, conn} <- AMQP.Connection.open(url),
           {:ok, chan} <- AMQP.Channel.open(conn) do
        AMQP.Queue.delete(chan, queue)
        AMQP.Connection.close(conn)
      end
    catch
      :exit, _ -> :ok
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
  defmodule Messaging.Events.AdminEventsConsumerTest do
    use ExUnit.Case

    test "skipped: set RABBITMQ_URL and MONGO_URL to run this against real services" do
      IO.puts("\nSkipping AdminEventsConsumer test: RABBITMQ_URL and MONGO_URL not set.\n")
    end
  end
end
