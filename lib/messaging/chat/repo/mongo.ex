defmodule Messaging.Chat.Repo.Mongo do
  @behaviour Messaging.Chat.Repo

  @conn Messaging.Mongo
  @messages "messages"
  @channels "channels"
  @blocks "blocks"
  @clocks "event_clocks"
  @mentions "mentions"
  @attachments "attachments"
  @reactions "reactions"
  @replica_servers "replica_servers"
  @replica_roles "replica_roles"
  @replica_members "replica_members"
  @replica_overrides "replica_overrides"
  @replica_users "replica_users"
  @replica_word_filters "replica_word_filters"
  @suspended_users "suspended_users"
  @tombstone_ttl_seconds 7 * 24 * 60 * 60

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
  def search_messages([], _opts), do: {:ok, []}

  def search_messages(channel_ids, opts) do
    filter = channel_ids |> search_filter(opts) |> older_than(opts[:before])
    sort = [inserted_at: -1, _id: -1]

    case Mongo.find(@conn, @messages, filter, sort: sort, limit: Keyword.fetch!(opts, :limit)) do
      {:error, reason} -> {:error, reason}
      cursor -> {:ok, Enum.to_list(cursor)}
    end
  rescue
    error -> {:error, error}
  end

  @impl true
  def count_search_matches([], _opts, _limit), do: {:ok, 0}

  def count_search_matches(channel_ids, opts, limit) do
    Mongo.count_documents(@conn, @messages, search_filter(channel_ids, opts), limit: limit)
  rescue
    error -> {:error, error}
  end

  defp search_filter(channel_ids, opts) do
    %{"channel_id" => %{"$in" => channel_ids}}
    |> live()
    |> containing(opts[:text])
    |> written_by(opts[:author_id])
  end

  defp containing(filter, nil), do: filter

  defp containing(filter, text),
    do: Map.put(filter, "content", %BSON.Regex{pattern: Regex.escape(text), options: "i"})

  defp written_by(filter, nil), do: filter
  defp written_by(filter, author_id), do: Map.put(filter, "user_id", author_id)

  defp older_than(filter, nil), do: filter

  defp older_than(filter, {%DateTime{} = at, id}) do
    Map.put(filter, "$or", [
      %{"inserted_at" => %{"$lt" => at}},
      %{"inserted_at" => at, "_id" => %{"$lt" => id}}
    ])
  end

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
      "$set" => %{
        "content" => "",
        "attachments" => [],
        "deleted_at" => deleted_at,
        "changed_at" => deleted_at
      }
    }

    case Mongo.find_one_and_update(@conn, @messages, filter, update, return_document: :after) do
      {:ok, %Mongo.FindAndModifyResult{value: doc}} -> {:ok, doc}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def get_message(id), do: Mongo.find_one(@conn, @messages, %{"_id" => id})

  @impl true
  def upsert_message(%{"_id" => id} = doc) do
    case Mongo.update_one(
           @conn,
           @messages,
           %{"_id" => id},
           %{"$setOnInsert" => Map.delete(doc, "_id")},
           upsert: true
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def apply_message_update(id, channel_id, fields) do
    filter = live(%{"_id" => id, "channel_id" => channel_id})

    case Mongo.update_one(@conn, @messages, filter, %{"$set" => fields}) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

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
  def add_reaction(%{"_id" => id} = doc) do
    update = %{"$setOnInsert" => Map.delete(doc, "_id")}

    case Mongo.update_one(@conn, @reactions, %{"_id" => id}, update, upsert: true) do
      {:ok, %Mongo.UpdateResult{upserted_ids: []}} -> {:ok, :unchanged}
      {:ok, %Mongo.UpdateResult{}} -> {:ok, :added}
      {:error, error} -> if duplicate_key?(error), do: {:ok, :unchanged}, else: {:error, error}
    end
  end

  @impl true
  def remove_reaction(id) do
    case Mongo.delete_one(@conn, @reactions, %{"_id" => id}) do
      {:ok, %Mongo.DeleteResult{deleted_count: 0}} -> {:ok, :unchanged}
      {:ok, %Mongo.DeleteResult{}} -> {:ok, :removed}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def count_reactions(message_id, emoji),
    do: Mongo.count_documents(@conn, @reactions, %{"message_id" => message_id, "emoji" => emoji})

  @impl true
  def reaction_emojis(message_id),
    do: Mongo.distinct(@conn, @reactions, "emoji", %{"message_id" => message_id})

  @impl true
  def list_reactions([]), do: {:ok, []}

  def list_reactions(message_ids) do
    case Mongo.find(@conn, @reactions, %{"message_id" => %{"$in" => message_ids}},
           sort: [inserted_at: 1, _id: 1]
         ) do
      {:error, reason} -> {:error, reason}
      cursor -> {:ok, Enum.to_list(cursor)}
    end
  rescue
    error -> {:error, error}
  end

  @impl true
  def delete_reactions(message_id) do
    case Mongo.delete_many(@conn, @reactions, %{"message_id" => message_id}) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def touch_message(id, at) do
    case Mongo.update_one(@conn, @messages, live(%{"_id" => id}), %{
           "$set" => %{"changed_at" => at}
         }) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
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
  def apply_clock(key, state, %DateTime{} = at, expires_at) do
    set = %{"state" => state, "at" => at}
    set = if expires_at, do: Map.put(set, "expires_at", expires_at), else: set
    filter = %{"_id" => key, "at" => %{"$lte" => at}}

    upsert_clock(filter, set, 1)
  end

  # A duplicate key means either a newer clock exists (stale) or a concurrent upsert
  # inserted the document between our match and our insert. Retrying once tells them apart.
  defp upsert_clock(filter, set, retries) do
    case Mongo.update_one(@conn, @clocks, filter, %{"$set" => set}, upsert: true) do
      {:ok, _result} ->
        {:ok, :applied}

      {:error, error} ->
        cond do
          not duplicate_key?(error) -> {:error, error}
          retries > 0 -> upsert_clock(filter, set, retries - 1)
          true -> {:ok, :stale}
        end
    end
  end

  defp duplicate_key?(%Mongo.WriteError{write_errors: [%{"code" => 11_000} | _]}), do: true
  defp duplicate_key?(%{code: 11_000}), do: true
  defp duplicate_key?(_other), do: false

  @impl true
  def get_clock(key), do: Mongo.find_one(@conn, @clocks, %{"_id" => key})

  @impl true
  def list_channel_ids(server_id) do
    {:ok, cached_channel_ids(server_id)}
  rescue
    error -> {:error, error}
  end

  @impl true
  def list_text_channel_ids(server_id) do
    filter = %{"server_id" => server_id, "kind" => "text"}

    case Mongo.find(@conn, @channels, filter, projection: %{"_id" => 1}) do
      {:error, reason} -> {:error, reason}
      cursor -> {:ok, Enum.map(cursor, & &1["_id"])}
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
         {:ok, _result} <- Mongo.delete_many(@conn, @mentions, %{"channel_id" => channel_id}),
         {:ok, _result} <- Mongo.delete_many(@conn, @reactions, %{"channel_id" => channel_id}),
         {:ok, _result} <- Mongo.delete_one(@conn, @replica_overrides, %{"_id" => channel_id}),
         :ok <- orphan_channel_attachments([channel_id]),
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
         {:ok, _result} <-
           Mongo.delete_many(@conn, @reactions, %{"channel_id" => %{"$in" => all_ids}}),
         {:ok, _result} <- delete_replica(server_id),
         :ok <- orphan_channel_attachments(all_ids),
         {:ok, _result} <- Mongo.delete_many(@conn, @channels, %{"server_id" => server_id}) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp orphan_channel_attachments(channel_ids) do
    filter = %{"channel_id" => %{"$in" => channel_ids}, "orphaned_at" => nil}

    update = %{
      "$set" => %{"orphaned_at" => DateTime.utc_now() |> DateTime.truncate(:millisecond)}
    }

    case Mongo.update_many(@conn, @attachments, filter, update) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def insert_attachment(doc) do
    case Mongo.insert_one(@conn, @attachments, doc) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def count_pending_attachments(user_id) do
    case Mongo.count_documents(
           @conn,
           @attachments,
           %{"user_id" => user_id, "message_id" => nil, "orphaned_at" => nil}
         ) do
      {:ok, count} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def claim_attachments([], _user_id, _channel_id, _message_id), do: {:ok, []}

  def claim_attachments(ids, user_id, channel_id, message_id) do
    filter = %{
      "_id" => %{"$in" => ids},
      "user_id" => user_id,
      "channel_id" => channel_id,
      "message_id" => nil,
      "orphaned_at" => nil
    }

    update = %{"$set" => %{"message_id" => message_id}}

    with {:ok, %Mongo.UpdateResult{modified_count: count}} <-
           Mongo.update_many(@conn, @attachments, filter, update),
         :ok <- ensure_claimed(count, length(ids), message_id) do
      docs = @conn |> Mongo.find(@attachments, %{"message_id" => message_id}) |> Enum.to_list()
      by_id = Map.new(docs, &{&1["_id"], &1})
      {:ok, Enum.map(ids, &Map.fetch!(by_id, &1))}
    end
  rescue
    error -> {:error, error}
  end

  defp ensure_claimed(count, count, _message_id), do: :ok

  defp ensure_claimed(_count, _expected, message_id) do
    _ = release_attachments(message_id)
    {:error, :invalid_attachment}
  end

  @impl true
  def release_attachments(message_id) do
    case Mongo.update_many(
           @conn,
           @attachments,
           %{"message_id" => message_id},
           %{"$set" => %{"message_id" => nil}}
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def orphan_message_attachments(message_id, %DateTime{} = at) do
    case Mongo.update_many(
           @conn,
           @attachments,
           %{"message_id" => message_id},
           %{"$set" => %{"orphaned_at" => at}}
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def list_cleanable_attachments(%DateTime{} = pending_before, limit) do
    filter = %{
      "$or" => [
        %{"orphaned_at" => %{"$ne" => nil}},
        %{"message_id" => nil, "uploaded_at" => %{"$lt" => pending_before}}
      ]
    }

    case Mongo.find(@conn, @attachments, filter, limit: limit) do
      {:error, reason} -> {:error, reason}
      cursor -> {:ok, Enum.to_list(cursor)}
    end
  rescue
    error -> {:error, error}
  end

  @impl true
  def delete_attachments(ids) do
    case Mongo.delete_many(@conn, @attachments, %{"_id" => %{"$in" => ids}}) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_replica(server_id) do
    filter = %{"server_id" => server_id}

    with {:ok, _result} <- Mongo.delete_many(@conn, @replica_overrides, filter),
         {:ok, _result} <- Mongo.delete_many(@conn, @replica_members, filter),
         {:ok, _result} <- Mongo.delete_many(@conn, @replica_roles, filter),
         {:ok, _result} <- Mongo.delete_one(@conn, @replica_word_filters, %{"_id" => server_id}) do
      Mongo.delete_one(@conn, @replica_servers, %{"_id" => server_id})
    end
  end

  @impl true
  def apply_server_owner(server_id, owner_id, %DateTime{} = at),
    do: apply_snapshot(@replica_servers, server_id, %{"owner_id" => owner_id}, at)

  @impl true
  def apply_role(server_id, role_id, permissions, is_everyone, %DateTime{} = at) do
    fields = %{
      "server_id" => server_id,
      "permissions" => permissions,
      "is_everyone" => is_everyone
    }

    apply_snapshot(@replica_roles, role_id, fields, at)
  end

  @impl true
  def delete_role(server_id, role_id, %DateTime{} = at) do
    with {:ok, :applied} <-
           apply_tombstone(@replica_roles, role_id, %{"server_id" => server_id}, at),
         {:ok, _result} <-
           Mongo.update_many(
             @conn,
             @replica_members,
             %{"server_id" => server_id},
             %{"$pull" => %{"role_ids" => role_id}}
           ),
         {:ok, _result} <-
           Mongo.update_many(
             @conn,
             @replica_overrides,
             %{"server_id" => server_id},
             %{"$pull" => %{"overrides" => %{"role_id" => role_id}}}
           ) do
      {:ok, :applied}
    end
  end

  @impl true
  def apply_member_roles(server_id, user_id, role_ids, %DateTime{} = at) do
    fields = %{"server_id" => server_id, "user_id" => user_id, "role_ids" => role_ids}
    apply_snapshot(@replica_members, member_key(server_id, user_id), fields, at)
  end

  @impl true
  def delete_member(server_id, user_id, %DateTime{} = at) do
    fields = %{"server_id" => server_id, "user_id" => user_id, "role_ids" => []}
    apply_tombstone(@replica_members, member_key(server_id, user_id), fields, at)
  end

  @impl true
  def apply_channel_overrides(server_id, channel_id, overrides, %DateTime{} = at) do
    fields = %{
      "server_id" => server_id,
      "overrides" =>
        Enum.map(overrides, fn o ->
          %{"role_id" => o.role_id, "allow" => o.allow, "deny" => o.deny}
        end)
    }

    apply_snapshot(@replica_overrides, channel_id, fields, at)
  end

  @impl true
  def apply_word_filter(server_id, words, %DateTime{} = at),
    do: apply_snapshot(@replica_word_filters, server_id, %{"words" => words}, at)

  @impl true
  def get_word_filter(server_id) do
    case Mongo.find_one(@conn, @replica_word_filters, %{
           "_id" => server_id,
           "deleted" => %{"$ne" => true}
         }) do
      %{"words" => words} -> {:ok, words}
      nil -> {:ok, []}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def apply_profile(user_id, version) do
    filter = %{"_id" => user_id, "version" => %{"$lt" => version}}

    case Mongo.update_one(@conn, @replica_users, filter, %{"$set" => %{"version" => version}},
           upsert: true
         ) do
      {:ok, _result} -> {:ok, :applied}
      {:error, error} -> if duplicate_key?(error), do: {:ok, :stale}, else: {:error, error}
    end
  end

  @impl true
  def apply_suspension(user_id, suspended, version) do
    filter = %{"_id" => user_id, "version" => %{"$lt" => version}}

    update = %{
      "$set" => %{
        "suspended" => suspended,
        "version" => version,
        "updated_at" => DateTime.utc_now()
      }
    }

    case Mongo.update_one(@conn, @suspended_users, filter, update, upsert: true) do
      {:ok, _result} -> {:ok, :applied}
      {:error, error} -> if duplicate_key?(error), do: {:ok, :stale}, else: {:error, error}
    end
  end

  @impl true
  def suspended?(user_id) do
    case Mongo.find_one(@conn, @suspended_users, %{"_id" => user_id}) do
      %{"suspended" => suspended} -> suspended
      nil -> false
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def get_server_owner(server_id) do
    case Mongo.find_one(@conn, @replica_servers, %{"_id" => server_id}) do
      %{"owner_id" => owner_id} -> owner_id
      nil -> nil
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def get_member(server_id, user_id) do
    Mongo.find_one(@conn, @replica_members, %{
      "_id" => member_key(server_id, user_id),
      "deleted" => %{"$ne" => true}
    })
  end

  @impl true
  def get_members(_server_id, []), do: {:ok, []}

  def get_members(server_id, user_ids) do
    keys = Enum.map(user_ids, &member_key(server_id, &1))
    list(@replica_members, %{"_id" => %{"$in" => keys}, "deleted" => %{"$ne" => true}})
  end

  @impl true
  def list_members(server_id) do
    list(@replica_members, %{"server_id" => server_id, "deleted" => %{"$ne" => true}})
  end

  @impl true
  def list_roles(server_id) do
    list(@replica_roles, %{"server_id" => server_id, "deleted" => %{"$ne" => true}})
  end

  @impl true
  def get_channel_overrides(channel_id) do
    case Mongo.find_one(@conn, @replica_overrides, %{"_id" => channel_id}) do
      %{"overrides" => overrides} -> {:ok, overrides}
      nil -> {:ok, []}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def list_channel_overrides([]), do: {:ok, %{}}

  def list_channel_overrides(channel_ids) do
    with {:ok, docs} <- list(@replica_overrides, %{"_id" => %{"$in" => channel_ids}}) do
      {:ok, Map.new(docs, &{&1["_id"], Map.get(&1, "overrides", [])})}
    end
  end

  @impl true
  def user_known?(user_id) do
    case Mongo.find_one(@conn, @replica_users, %{"_id" => user_id}, projection: %{"_id" => 1}) do
      nil -> false
      {:error, _reason} = error -> error
      _doc -> true
    end
  end

  defp list(collection, filter) do
    case Mongo.find(@conn, collection, filter) do
      {:error, reason} -> {:error, reason}
      cursor -> {:ok, Enum.to_list(cursor)}
    end
  rescue
    error -> {:error, error}
  end

  defp member_key(server_id, user_id), do: "#{server_id}:#{user_id}"

  defp apply_snapshot(collection, id, fields, at) do
    update = %{
      "$set" => fields |> Map.merge(%{"at" => at, "deleted" => false}),
      "$unset" => %{"expires_at" => ""}
    }

    write_if_newer(collection, id, at, update)
  end

  defp apply_tombstone(collection, id, fields, at) do
    expires_at = DateTime.add(DateTime.utc_now(), @tombstone_ttl_seconds, :second)

    update = %{
      "$set" => Map.merge(fields, %{"at" => at, "deleted" => true, "expires_at" => expires_at})
    }

    write_if_newer(collection, id, at, update)
  end

  defp write_if_newer(collection, id, at, update) do
    filter = %{"_id" => id, "at" => %{"$lte" => at}}

    case Mongo.update_one(@conn, collection, filter, update, upsert: true) do
      {:ok, _result} -> {:ok, :applied}
      {:error, error} -> if duplicate_key?(error), do: {:ok, :stale}, else: {:error, error}
    end
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
      ],
      [
        name: "messages_channel_user_inserted_at_id",
        key: [channel_id: 1, user_id: 1, inserted_at: -1, _id: -1]
      ]
    ]

    channel_indexes = [
      [
        name: "dm_participants_last_message_at",
        key: [participants: 1, last_message_at: -1],
        partialFilterExpression: %{"kind" => "dm"}
      ],
      [name: "channels_server_kind", key: [server_id: 1, kind: 1]]
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

    reaction_indexes = [
      [name: "reactions_message_emoji", key: [message_id: 1, emoji: 1]],
      [name: "reactions_channel", key: [channel_id: 1]]
    ]

    clock_indexes = [
      [name: "event_clocks_expires_at_ttl", key: [expires_at: 1], expireAfterSeconds: 0]
    ]

    attachment_indexes = [
      [name: "attachments_user_message", key: [user_id: 1, message_id: 1]],
      [name: "attachments_message", key: [message_id: 1]],
      [name: "attachments_channel", key: [channel_id: 1]],
      [
        name: "attachments_orphaned_at",
        key: [orphaned_at: 1],
        partialFilterExpression: %{"orphaned_at" => %{"$exists" => true}}
      ]
    ]

    replica_ttl = [[name: "replica_expires_at_ttl", key: [expires_at: 1], expireAfterSeconds: 0]]
    replica_by_server = [[name: "replica_server", key: [server_id: 1]]]

    with :ok <- Mongo.create_indexes(@conn, @messages, indexes),
         :ok <- Mongo.create_indexes(@conn, @channels, channel_indexes),
         :ok <- Mongo.create_indexes(@conn, @blocks, block_indexes),
         :ok <- Mongo.create_indexes(@conn, @mentions, mention_indexes),
         :ok <- Mongo.create_indexes(@conn, @attachments, attachment_indexes),
         :ok <- Mongo.create_indexes(@conn, @reactions, reaction_indexes),
         :ok <- Mongo.create_indexes(@conn, @replica_roles, replica_ttl ++ replica_by_server),
         :ok <- Mongo.create_indexes(@conn, @replica_members, replica_ttl ++ replica_by_server),
         :ok <- Mongo.create_indexes(@conn, @replica_overrides, replica_by_server) do
      Mongo.create_indexes(@conn, @clocks, clock_indexes)
    end
  end
end
