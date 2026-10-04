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
    limit = Keyword.fetch!(opts, :limit)
    {filter, direction} = page_query(channel_id, opts[:before], opts[:after])

    case Mongo.find(@conn, @messages, filter,
           sort: [inserted_at: direction, _id: direction],
           limit: limit
         ) do
      {:error, reason} -> {:error, reason}
      cursor -> {:ok, Enum.to_list(cursor)}
    end
  rescue
    error -> {:error, error}
  end

  defp page_query(channel_id, nil, nil), do: {live(%{"channel_id" => channel_id}), -1}

  defp page_query(channel_id, {%DateTime{} = at, id}, nil),
    do: {keyset(channel_id, "$lt", at, id), -1}

  defp page_query(channel_id, nil, {%DateTime{} = at, id}),
    do: {keyset(channel_id, "$gt", at, id), 1}

  defp keyset(channel_id, op, at, id) do
    live(%{
      "channel_id" => channel_id,
      "$or" => [
        %{"inserted_at" => %{op => at}},
        %{"inserted_at" => at, "_id" => %{op => id}}
      ]
    })
  end

  defp live(filter), do: Map.put(filter, "deleted_at", nil)

  @impl true
  def update_message(id, channel_id, user_id, content, edited_at) do
    filter = live(%{"_id" => id, "channel_id" => channel_id, "user_id" => user_id})

    update = %{
      "$set" => %{"content" => content, "edited_at" => edited_at, "changed_at" => edited_at}
    }

    case Mongo.find_one_and_update(@conn, @messages, filter, update, return_document: :after) do
      {:ok, %Mongo.FindAndModifyResult{value: doc}} -> {:ok, doc}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete_message(id, channel_id, deleted_at) do
    filter = live(%{"_id" => id, "channel_id" => channel_id})

    update = %{
      "$set" => %{"content" => "", "deleted_at" => deleted_at, "changed_at" => deleted_at}
    }

    case Mongo.find_one_and_update(@conn, @messages, filter, update, return_document: :after) do
      {:ok, %Mongo.FindAndModifyResult{value: doc}} -> {:ok, doc}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def get_message(id), do: Mongo.find_one(@conn, @messages, %{"_id" => id})

  @impl true
  def list_changes(channel_id, %DateTime{} = since, limit) do
    filter = %{"channel_id" => channel_id, "changed_at" => %{"$gte" => since}}

    case Mongo.find(@conn, @messages, filter,
           sort: [changed_at: 1, _id: 1],
           limit: limit
         ) do
      {:error, reason} -> {:error, reason}
      cursor -> {:ok, Enum.to_list(cursor)}
    end
  rescue
    error -> {:error, error}
  end

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
    with {:ok, _result} <- Mongo.delete_many(@conn, @messages, %{"channel_id" => channel_id}),
         {:ok, _result} <- Mongo.delete_one(@conn, @channels, %{"_id" => channel_id}) do
      :ok
    end
  end

  @impl true
  def delete_server_data(server_id, channel_ids) do
    channels = cached_channel_ids(server_id)
    all_ids = Enum.uniq(channel_ids ++ channels)

    with {:ok, _result} <-
           Mongo.delete_many(@conn, @messages, %{"channel_id" => %{"$in" => all_ids}}),
         {:ok, _result} <- Mongo.delete_many(@conn, @channels, %{"server_id" => server_id}) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp cached_channel_ids(server_id) do
    @conn
    |> Mongo.find(@channels, %{"server_id" => server_id}, projection: %{"_id" => 1})
    |> Enum.map(& &1["_id"])
  end

  @impl true
  def ping do
    case Mongo.ping(@conn) do
      {:ok, _doc} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def ensure_indexes do
    indexes = [
      [name: "messages_channel_inserted_at_id", key: [channel_id: 1, inserted_at: -1, _id: -1]],
      [
        name: "messages_channel_changed_at",
        key: [channel_id: 1, changed_at: 1],
        partialFilterExpression: %{"changed_at" => %{"$exists" => true}}
      ]
    ]

    Mongo.create_indexes(@conn, @messages, indexes)
  end
end
