rabbitmq_url = System.get_env("RABBITMQ_URL")
mongo_url = System.get_env("MONGO_URL")

if rabbitmq_url && mongo_url do
  defmodule Messaging.Events.BillingEventsConsumerTest do
    use ExUnit.Case, async: false
    import ExUnit.CaptureLog

    alias Messaging.Chat.Repo.Mongo, as: Repo
    alias Messaging.Events.BillingEventsConsumer
    alias Messaging.Premium
    alias Messaging.Premium.Signature

    @exchange "discordia.events"
    @secret "integration-secret"
    @routing_key "billing.premium_updated"

    setup do
      previous_repo = Application.get_env(:messaging, :chat_repo)
      Application.put_env(:messaging, :chat_repo, Repo)
      on_exit(fn -> Application.put_env(:messaging, :chat_repo, previous_repo) end)

      rabbitmq_url = System.fetch_env!("RABBITMQ_URL")
      queue = "messaging.billing_events.test-#{System.unique_integer([:positive])}"

      start_supervised!({BillingEventsConsumer, url: rabbitmq_url, queue: queue, secret: @secret})

      assert wait_until(fn ->
               match?(%{chan: %AMQP.Channel{}}, :sys.get_state(BillingEventsConsumer))
             end)

      {:ok, conn} = AMQP.Connection.open(rabbitmq_url)
      {:ok, chan} = AMQP.Channel.open(conn)

      on_exit(fn ->
        AMQP.Queue.delete(chan, queue)
        AMQP.Connection.close(conn)
      end)

      {:ok, chan: chan, user: Messaging.UUID.generate()}
    end

    test "a signed event makes the user Premium and a newer one ends it", %{
      chan: chan,
      user: user
    } do
      publish(chan, signed(user, true, 1, @secret))
      assert wait_until(fn -> Premium.premium?(user) == {:ok, true} end)

      publish(chan, signed(user, false, 2, @secret))
      assert wait_until(fn -> Premium.premium?(user) == {:ok, false} end)
    end

    test "an event signed with another secret is dropped and the queue keeps going", %{
      chan: chan,
      user: user
    } do
      log =
        capture_log([level: :warning], fn ->
          publish(chan, signed(user, true, 1, "forged"))
          publish(chan, signed(user, false, 2, @secret))
          assert wait_until(fn -> Repo.premium?(user) == false and has_version?(user) end)
        end)

      assert log =~ "billing_events_consumer_invalid_signature"
    end

    defp has_version?(user) do
      match?(
        %{"version" => 2},
        Mongo.find_one(Messaging.Mongo, "premium_users", %{"_id" => user})
      )
    end

    defp publish(chan, payload) do
      :ok = AMQP.Basic.publish(chan, @exchange, @routing_key, payload)
    end

    defp signed(user_id, active, version, secret) do
      event = %{
        "event_id" => Messaging.UUID.generate(),
        "occurred_at" => "2026-11-03T12:30:45.5Z",
        "user_id" => user_id,
        "active" => active,
        "premium_until" => if(active, do: "2026-12-03T12:30:45Z"),
        "renews" => active,
        "version" => version
      }

      event |> Map.put("signature", Signature.sign(event, secret)) |> Jason.encode!()
    end

    defp wait_until(fun, attempts \\ 50) do
      cond do
        fun.() ->
          true

        attempts == 0 ->
          false

        true ->
          Process.sleep(100)
          wait_until(fun, attempts - 1)
      end
    end
  end
end
