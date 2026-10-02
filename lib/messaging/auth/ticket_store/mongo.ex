defmodule Messaging.Auth.TicketStore.Mongo do
  @behaviour Messaging.Auth.TicketStore

  @conn Messaging.Mongo
  @collection "socket_tickets"
  @index_ready_key {__MODULE__, :index_ready}

  @impl true
  def put(doc) do
    ensure_ttl_index()

    case Mongo.insert_one(@conn, @collection, doc) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def take(id), do: Mongo.find_one_and_delete(@conn, @collection, %{"_id" => id})

  defp ensure_ttl_index do
    unless :persistent_term.get(@index_ready_key, false) do
      indexes = [
        [name: "socket_tickets_expires_at_ttl", key: [expires_at: 1], expireAfterSeconds: 0]
      ]

      if Mongo.create_indexes(@conn, @collection, indexes) == :ok do
        :persistent_term.put(@index_ready_key, true)
      end
    end

    :ok
  end
end
