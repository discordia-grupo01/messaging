defmodule Messaging.Presence.Store.Mongo do
  @behaviour Messaging.Presence.Store

  alias Messaging.Presence.Status

  @conn Messaging.Mongo
  @presence "presence"
  @instances "presence_instances"
  @replica_members "replica_members"
  @channels "channels"

  @impl true
  def change(user_id, change), do: change(user_id, change, 1)

  defp change(user_id, change, attempt) do
    {filter, update, upsert} = command(user_id, change)

    case Mongo.find_one_and_update(@conn, @presence, filter, update,
           upsert: upsert,
           return_document: :before
         ) do
      {:ok, %Mongo.FindAndModifyResult{value: nil, upserted_id: nil}} ->
        {:ok, :unchanged}

      {:ok, %Mongo.FindAndModifyResult{value: before}} ->
        {:ok, {:changed, before}}

      {:error, error} ->
        cond do
          not duplicate_key?(error) -> {:error, error}
          attempt == 1 -> change(user_id, change, 2)
          true -> {:ok, :unchanged}
        end
    end
  end

  defp command(user_id, {:connect, conn_id, instance_id}) do
    connection =
      conn_id
      |> Status.connection(instance_id)
      |> Map.put("since", now())

    {%{"_id" => user_id},
     %{
       "$push" => %{"connections" => connection},
       "$setOnInsert" => %{"manual" => Status.default_choice()},
       "$set" => %{"updated_at" => now()},
       "$inc" => %{"version" => 1}
     }, true}
  end

  defp command(user_id, {:disconnect, conn_id}) do
    {%{"_id" => user_id, "connections.id" => conn_id},
     %{
       "$pull" => %{"connections" => %{"id" => conn_id}},
       "$set" => %{"updated_at" => now()},
       "$inc" => %{"version" => 1}
     }, false}
  end

  defp command(user_id, {:activity, conn_id, idle}) do
    {%{
       "_id" => user_id,
       "connections" => %{"$elemMatch" => %{"id" => conn_id, "idle" => %{"$ne" => idle}}}
     },
     %{
       "$set" => %{"connections.$.idle" => idle, "updated_at" => now()},
       "$inc" => %{"version" => 1}
     }, false}
  end

  defp command(user_id, {:set_manual, choice}) do
    {%{"_id" => user_id, "manual" => %{"$ne" => choice}},
     %{
       "$set" => %{"manual" => choice, "updated_at" => now()},
       "$setOnInsert" => %{"connections" => []},
       "$inc" => %{"version" => 1}
     }, true}
  end

  defp command(user_id, {:drop_instance, instance_id}) do
    {%{"_id" => user_id, "connections.instance" => instance_id},
     %{
       "$pull" => %{"connections" => %{"instance" => instance_id}},
       "$set" => %{"updated_at" => now()},
       "$inc" => %{"version" => 1}
     }, false}
  end

  @impl true
  def get_many([]), do: {:ok, []}
  def get_many(user_ids), do: list(@presence, %{"_id" => %{"$in" => Enum.uniq(user_ids)}})

  @impl true
  def user_ids_on_instance(instance_id) do
    with {:ok, docs} <-
           list(@presence, %{"connections.instance" => instance_id}, projection: %{"_id" => 1}) do
      {:ok, Enum.map(docs, & &1["_id"])}
    end
  end

  @impl true
  def heartbeat(instance_id, %DateTime{} = at) do
    case Mongo.update_one(
           @conn,
           @instances,
           %{"_id" => instance_id},
           %{"$set" => %{"seen_at" => at}},
           upsert: true
         ) do
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def stale_instances(%DateTime{} = seen_before) do
    with {:ok, docs} <-
           list(@instances, %{"seen_at" => %{"$lt" => seen_before}}, projection: %{"_id" => 1}) do
      {:ok, Enum.map(docs, & &1["_id"])}
    end
  end

  @impl true
  def delete_instance(instance_id) do
    case Mongo.delete_one(@conn, @instances, %{"_id" => instance_id}) do
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def member_server_ids(user_id) do
    with {:ok, docs} <-
           list(
             @replica_members,
             %{"user_id" => user_id, "deleted" => %{"$ne" => true}},
             projection: %{"server_id" => 1}
           ) do
      {:ok, docs |> Enum.map(& &1["server_id"]) |> Enum.reject(&is_nil/1) |> Enum.uniq()}
    end
  end

  @impl true
  def dm_partner_ids(user_id, limit) do
    with {:ok, docs} <-
           list(
             @channels,
             %{"kind" => "dm", "participants" => user_id},
             projection: %{"participants" => 1},
             sort: %{"last_message_at" => -1},
             limit: limit
           ) do
      {:ok,
       docs
       |> Enum.flat_map(&Map.get(&1, "participants", []))
       |> Enum.reject(&(&1 == user_id))
       |> Enum.uniq()}
    end
  end

  @impl true
  def ensure_indexes do
    with :ok <-
           Mongo.create_indexes(@conn, @presence, [
             [name: "presence_connections_instance", key: ["connections.instance": 1]]
           ]),
         :ok <-
           Mongo.create_indexes(@conn, @instances, [
             [name: "presence_instances_seen_at", key: [seen_at: 1]]
           ]) do
      Mongo.create_indexes(@conn, @replica_members, [
        [name: "replica_member_user", key: [user_id: 1]]
      ])
    end
  end

  defp list(collection, filter, opts \\ []) do
    case Mongo.find(@conn, collection, filter, opts) do
      {:error, reason} -> {:error, reason}
      cursor -> {:ok, Enum.to_list(cursor)}
    end
  rescue
    error -> {:error, error}
  end

  defp duplicate_key?(%Mongo.WriteError{write_errors: [%{"code" => 11_000} | _]}), do: true
  defp duplicate_key?(%{code: 11_000}), do: true
  defp duplicate_key?(_other), do: false

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:millisecond)
end
