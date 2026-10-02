defmodule Messaging.Chat.Repo.Mongo do
  @behaviour Messaging.Chat.Repo

  @conn Messaging.Mongo
  @messages "messages"
  @channels "channels"

  @impl true
  def insert_message(doc) do
    case Mongo.insert_one(@conn, @messages, doc) do
      {:ok, _result} -> {:ok, doc}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def list_messages(channel_id, opts) do
    filter =
      case Keyword.get(opts, :before) do
        nil -> %{"channel_id" => channel_id}
        %DateTime{} = dt -> %{"channel_id" => channel_id, "inserted_at" => %{"$lt" => dt}}
      end

    limit = Keyword.fetch!(opts, :limit)

    case Mongo.find(@conn, @messages, filter, sort: %{"inserted_at" => -1}, limit: limit) do
      {:error, reason} -> {:error, reason}
      cursor -> {:ok, Enum.to_list(cursor)}
    end
  rescue
    error -> {:error, error}
  end

  @impl true
  def get_message(id), do: Mongo.find_one(@conn, @messages, %{"_id" => id})

  @impl true
  def get_channel(channel_id), do: Mongo.find_one(@conn, @channels, %{"_id" => channel_id})

  @impl true
  def upsert_channel(%{"_id" => id} = doc) do
    case Mongo.update_one(@conn, @channels, %{"_id" => id}, %{"$set" => doc}, upsert: true) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete_channel(channel_id) do
    case Mongo.delete_one(@conn, @channels, %{"_id" => channel_id}) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def ping do
    case Mongo.ping(@conn) do
      {:ok, _doc} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
