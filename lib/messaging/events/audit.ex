defmodule Messaging.Events.Audit do
  @conn Messaging.Mongo
  @collection "consumed_events"

  @type status ::
          :processed
          | :ignored_stale
          | :discarded_malformed_payload
          | :discarded_unknown_routing_key
          | :discarded_invalid_payload

  @type attrs :: %{
          optional(:event_id) => String.t() | nil,
          routing_key: String.t(),
          raw_body: binary(),
          status: status(),
          error: String.t() | nil
        }

  @spec record(attrs()) :: :ok | {:error, term()}
  def record(%{routing_key: routing_key, raw_body: raw_body, status: status} = attrs) do
    error = Map.get(attrs, :error)
    now = DateTime.utc_now()

    case Map.get(attrs, :event_id) do
      event_id when is_binary(event_id) and event_id != "" ->
        upsert_by_event_id(event_id, routing_key, raw_body, status, error, now)

      _no_event_id ->
        insert_without_event_id(routing_key, raw_body, status, error, now)
    end
  end

  defp upsert_by_event_id(event_id, routing_key, raw_body, status, error, now) do
    filter = %{"_id" => event_id}

    update = %{
      "$set" => %{
        "event_id" => event_id,
        "routing_key" => routing_key,
        "raw_body" => raw_body,
        "status" => to_string(status),
        "processed_at" => now,
        "error" => error
      },
      "$inc" => %{"attempts" => 1}
    }

    case Mongo.update_one(@conn, @collection, filter, update, upsert: true) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_without_event_id(routing_key, raw_body, status, error, now) do
    doc = %{
      "_id" => Messaging.UUID.generate(),
      "event_id" => nil,
      "routing_key" => routing_key,
      "raw_body" => raw_body,
      "status" => to_string(status),
      "attempts" => 1,
      "processed_at" => now,
      "error" => error
    }

    case Mongo.insert_one(@conn, @collection, doc) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
