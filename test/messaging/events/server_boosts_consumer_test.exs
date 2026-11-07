rabbitmq_url = System.get_env("RABBITMQ_URL")
mongo_url = System.get_env("MONGO_URL")

if rabbitmq_url && mongo_url do
  defmodule Messaging.Events.ServerBoostsConsumerTest do
    use ExUnit.Case, async: false

    alias Messaging.Chat.Repo.Mongo, as: Repo
    alias Messaging.Events.ServerBoostsConsumer

    @exchange "discordia.events"
    @routing_key "servers.server_boost_updated"

    setup do
      previous_repo = Application.get_env(:messaging, :chat_repo)
      Application.put_env(:messaging, :chat_repo, Repo)
      on_exit(fn -> Application.put_env(:messaging, :chat_repo, previous_repo) end)

      rabbitmq_url = System.fetch_env!("RABBITMQ_URL")
      queue = "messaging.server_boosts.test-#{System.unique_integer([:positive])}"

      start_supervised!({ServerBoostsConsumer, url: rabbitmq_url, queue: queue})

      assert wait_until(fn ->
               match?(%{chan: %AMQP.Channel{}}, :sys.get_state(ServerBoostsConsumer))
             end)

      {:ok, conn} = AMQP.Connection.open(rabbitmq_url)
      {:ok, chan} = AMQP.Channel.open(conn)

      on_exit(fn ->
        AMQP.Queue.delete(chan, queue)
        AMQP.Connection.close(conn)
      end)

      {:ok, chan: chan, server: Messaging.UUID.generate()}
    end

    test "the event reaches the level", %{chan: chan, server: server} do
      publish(chan, server, 2, 1)
      assert wait_until(fn -> Repo.server_boost_level(server) == 2 end)
    end

    test "an event that arrives late doesn't lower the level", %{chan: chan, server: server} do
      publish(chan, server, 2, 5)
      assert wait_until(fn -> Repo.server_boost_level(server) == 2 end)

      publish(chan, server, 0, 4)
      other = Messaging.UUID.generate()
      publish(chan, other, 1, 1)
      assert wait_until(fn -> Repo.server_boost_level(other) == 1 end)

      assert Repo.server_boost_level(server) == 2
    end

    defp publish(chan, server, level, version) do
      payload =
        Jason.encode!(%{
          "event_id" => Messaging.UUID.generate(),
          "occurred_at" => "2026-11-05T12:00:00Z",
          "server_id" => server,
          "boost_count" => 15,
          "level" => level,
          "version" => version
        })

      :ok = AMQP.Basic.publish(chan, @exchange, @routing_key, payload)
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
