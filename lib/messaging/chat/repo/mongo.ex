defmodule Messaging.Chat.Repo.Mongo do
  @behaviour Messaging.Chat.Repo

  @conn Messaging.Mongo
  @messages "messages"
  @channels "channels"
  @blocks "blocks"
  @mentions "mentions"

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
  def update_message(id, channel_id, user_id, content, edited_at, mention_fields) do
    filter = live(%{"_id" => id, "channel_id" => channel_id, "user_id" => user_id})

    update = %{
      "$set" =>
        Map.merge(mention_fields, %{
          "content" => content,
          "edited_at" => edited_at,
          "changed_at" => edited_at
        })
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
  def get_messages(ids) do
    filter = live(%{"_id" => %{"$in" => ids}})

    case Mongo.find(@conn, @messages, filter) do
      {:error, reason} -> {:error, reason}
      cursor -> {:ok, Enum.to_list(cursor)}
    end
  rescue
    error -> {:error, error}
  end

  @impl true
  def ensure_conversation(%{"_id" => id} = doc) do
    update = %{"$setOnInsert" => Map.delete(doc, "_id")}

    case Mongo.update_one(@conn, @channels, %{"_id" => id}, update, upsert: true) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def record_last_message(channel_id, message_id, user_id, at) do
    filter = %{
      "_id" => channel_id,
      "kind" => "dm",
      "$or" => [%{"last_message_at" => nil}, %{"last_message_at" => %{"$lte" => at}}]
    }

    update = %{
      "$set" => %{
        "last_message_id" => message_id,
        "last_message_user_id" => user_id,
        "last_message_at" => at
      }
    }

    case Mongo.update_one(@conn, @channels, filter, update) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def list_conversations(user_id, limit) do
    filter = %{"kind" => "dm", "participants" => user_id, "last_message_at" => %{"$ne" => nil}}

    case Mongo.find(@conn, @channels, filter, sort: [last_message_at: -1], limit: limit) do
      {:error, reason} -> {:error, reason}
      cursor -> {:ok, Enum.to_list(cursor)}
    end
  rescue
    error -> {:error, error}
  end

  @impl true
  def mark_read(channel_id, user_id, at) do
    filter = %{"_id" => channel_id, "kind" => "dm", "participants" => user_id}
    update = %{"$max" => %{"last_read_at.#{user_id}" => at}}

    case Mongo.update_one(@conn, @channels, filter, update) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def put_block(%{"_id" => id} = doc) do
    update = %{"$setOnInsert" => Map.delete(doc, "_id")}

    case Mongo.update_one(@conn, @blocks, %{"_id" => id}, update, upsert: true) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete_block(id) do
    case Mongo.delete_one(@conn, @blocks, %{"_id" => id}) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def get_blocks(ids) do
    case Mongo.find(@conn, @blocks, %{"_id" => %{"$in" => ids}}) do
      {:error, reason} -> {:error, reason}
      cursor -> {:ok, Enum.to_list(cursor)}
    end
  rescue
    error -> {:error, error}
  end

  @impl true
  def list_blocks(blocker_id, limit) do
    case Mongo.find(@conn, @blocks, %{"blocker_id" => blocker_id},
           sort: [created_at: -1, _id: 1],
           limit: limit
         ) do
      {:error, reason} -> {:error, reason}
      cursor -> {:ok, Enum.to_list(cursor)}
    end
  rescue
    error -> {:error, error}
  end

  @impl true
  def insert_mentions(docs) do
    Enum.reduce_while(docs, {:ok, []}, fn doc, {:ok, inserted} ->
      case insert_mention(doc) do
        {:ok, true} -> {:cont, {:ok, [doc["user_id"] | inserted]}}
        {:ok, false} -> {:cont, {:ok, inserted}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, inserted} -> {:ok, Enum.reverse(inserted)}
      error -> error
    end
  end

  defp insert_mention(%{"_id" => id} = doc) do
    update = %{"$setOnInsert" => Map.delete(doc, "_id")}

    case Mongo.update_one(@conn, @mentions, %{"_id" => id}, update, upsert: true) do
      {:ok, %Mongo.UpdateResult{upserted_ids: upserted}} -> {:ok, upserted != []}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete_mentions(message_id, keep_user_ids) do
    filter = %{"message_id" => message_id, "user_id" => %{"$nin" => keep_user_ids}}

    case Mongo.delete_many(@conn, @mentions, filter) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def list_unread_mentions(user_id, limit) do
    case Mongo.find(@conn, @mentions, %{"user_id" => user_id, "read_at" => nil},
           sort: [inserted_at: -1, _id: -1],
           limit: limit
         ) do
      {:error, reason} -> {:error, reason}
      cursor -> {:ok, Enum.to_list(cursor)}
    end
  rescue
    error -> {:error, error}
  end

  @impl true
  def mark_mentions_read(user_id, channel_id, at) do
    filter = %{"user_id" => user_id, "channel_id" => channel_id, "read_at" => nil}

    case Mongo.update_many(@conn, @mentions, filter, %{"$set" => %{"read_at" => at}}) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete_member_mentions(server_id, user_id) do
    case Mongo.delete_many(@conn, @mentions, %{"server_id" => server_id, "user_id" => user_id}) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
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
         {:ok, _result} <- Mongo.delete_many(@conn, @mentions, %{"channel_id" => channel_id}),
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
         {:ok, _result} <-
           Mongo.delete_many(@conn, @mentions, %{"channel_id" => %{"$in" => all_ids}}),
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

    channel_indexes = [
      [
        name: "dm_participants_last_message_at",
        key: [participants: 1, last_message_at: -1],
        partialFilterExpression: %{"kind" => "dm"}
      ]
    ]

    block_indexes = [[name: "blocks_blocker_created_at", key: [blocker_id: 1, created_at: -1]]]

    mention_indexes = [
      [
        name: "mentions_user_read_inserted_at",
        key: [user_id: 1, read_at: 1, inserted_at: -1, _id: -1]
      ],
      [name: "mentions_message", key: [message_id: 1]],
      [name: "mentions_channel", key: [channel_id: 1]],
      [name: "mentions_server_user", key: [server_id: 1, user_id: 1]]
    ]

    with :ok <- Mongo.create_indexes(@conn, @messages, indexes),
         :ok <- Mongo.create_indexes(@conn, @channels, channel_indexes),
         :ok <- Mongo.create_indexes(@conn, @blocks, block_indexes) do
      Mongo.create_indexes(@conn, @mentions, mention_indexes)
    end
  end
end
