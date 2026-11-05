rabbitmq_url = System.get_env("RABBITMQ_URL")
mongo_url = System.get_env("MONGO_URL")

if rabbitmq_url && mongo_url do
  defmodule Messaging.Events.ServerEmojisConsumerTest do
    use ExUnit.Case, async: false

    alias Messaging.Chat.Repo.Mongo, as: Repo
    alias Messaging.Events.ServerEmojisConsumer

    @exchange "discordia.events"

    setup do
      previous_repo = Application.get_env(:messaging, :chat_repo)
      Application.put_env(:messaging, :chat_repo, Repo)
      on_exit(fn -> Application.put_env(:messaging, :chat_repo, previous_repo) end)

      rabbitmq_url = System.fetch_env!("RABBITMQ_URL")
      queue = "messaging.server_emojis.test-#{System.unique_integer([:positive])}"

      start_supervised!({ServerEmojisConsumer, url: rabbitmq_url, queue: queue})

      assert wait_until(fn ->
               match?(%{chan: %AMQP.Channel{}}, :sys.get_state(ServerEmojisConsumer))
             end)

      {:ok, conn} = AMQP.Connection.open(rabbitmq_url)
      {:ok, chan} = AMQP.Channel.open(conn)

      on_exit(fn ->
        AMQP.Queue.delete(chan, queue)
        AMQP.Connection.close(conn)
      end)

      {:ok, chan: chan, id: Messaging.UUID.generate()}
    end

    test "created and deleted events reach the replica", %{chan: chan, id: id} do
      publish(chan, "servers.emoji_created", id)
      assert wait_until(fn -> match?(%{"deleted" => false}, fetch(id)) end)

      publish(chan, "servers.emoji_deleted", id)
      assert wait_until(fn -> match?(%{"deleted" => true}, fetch(id)) end)
    end

    test "the deletion wins when it arrives first", %{chan: chan, id: id} do
      publish(chan, "servers.emoji_deleted", id)
      assert wait_until(fn -> match?(%{"deleted" => true}, fetch(id)) end)

      publish(chan, "servers.emoji_created", id)
      other = Messaging.UUID.generate()
      publish(chan, "servers.emoji_created", other)
      assert wait_until(fn -> match?(%{"deleted" => false}, fetch(other)) end)

      assert %{"deleted" => true} = fetch(id)
    end

    defp fetch(id) do
      case Repo.get_custom_emojis([id]) do
        {:ok, [doc]} -> doc
        _other -> nil
      end
    end

    defp publish(chan, routing_key, id) do
      payload =
        Jason.encode!(%{
          "event_id" => Messaging.UUID.generate(),
          "occurred_at" => "2026-11-05T12:00:00Z",
          "emoji_id" => id,
          "server_id" => Messaging.UUID.generate(),
          "name" => "party",
          "animated" => true,
          "image_url" => "https://cdn.test/party.gif"
        })

      :ok = AMQP.Basic.publish(chan, @exchange, routing_key, payload)
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
