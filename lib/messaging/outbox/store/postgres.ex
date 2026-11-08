defmodule Messaging.Outbox.Store.Postgres do
  @behaviour Messaging.Outbox.Store

  alias Messaging.Postgres

  @max_attempts 10
  @insert_timeout 5_000
  @process_timeout 30_000

  @impl true
  def insert(rows) do
    result =
      Postgrex.transaction(
        Postgres,
        fn conn ->
          Enum.each(rows, fn row ->
            case Postgrex.query(conn, insert_sql(), insert_params(row)) do
              {:ok, %Postgrex.Result{num_rows: 0}} -> DBConnection.rollback(conn, :duplicate)
              {:ok, _result} -> :ok
              {:error, reason} -> DBConnection.rollback(conn, reason)
            end
          end)
        end,
        timeout: @insert_timeout
      )

    case result do
      {:ok, _} -> :ok
      {:error, :duplicate} -> :duplicate
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  @impl true
  def process_pending(limit, handler) do
    result =
      Postgrex.transaction(
        Postgres,
        fn conn ->
          rows = select_pending(conn, limit)
          outcomes = handler.(rows)
          Enum.each(outcomes, &record(conn, &1))
          Enum.count(outcomes, &match?({_id, :ok}, &1))
        end,
        timeout: @process_timeout
      )

    case result do
      {:ok, count} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  @impl true
  defdelegate ping, to: Postgres

  defp table, do: ~s("#{Postgres.schema()}".outbox_events)

  defp insert_sql do
    """
    INSERT INTO #{table()} (id, event, topic, payload, apply, message_id, channel_id, traceparent)
    VALUES ($1::text::uuid, $2, $3, $4::text::jsonb, $5::text::jsonb, $6, $7, $8)
    ON CONFLICT DO NOTHING
    """
  end

  defp insert_params(row) do
    [
      row.id,
      row.event,
      row.topic,
      Jason.encode!(row.payload),
      encode_optional(Map.get(row, :apply)),
      Map.get(row, :message_id),
      Map.get(row, :channel_id),
      Map.get(row, :traceparent)
    ]
  end

  defp encode_optional(nil), do: nil
  defp encode_optional(map), do: Jason.encode!(map)

  defp select_pending(conn, limit) do
    sql = """
    SELECT o.id::text, o.event, o.topic, o.payload::text, o.apply::text,
           o.message_id, o.channel_id, o.traceparent, o.attempts
      FROM #{table()} o
     WHERE o.published_at IS NULL
       AND o.attempts < $2
       AND NOT EXISTS (
             SELECT 1 FROM #{table()} earlier
              WHERE earlier.message_id = o.message_id
                AND earlier.published_at IS NULL
                AND (earlier.created_at, earlier.id) < (o.created_at, o.id))
     ORDER BY o.created_at, o.id
     LIMIT $1
       FOR UPDATE OF o SKIP LOCKED
    """

    %Postgrex.Result{rows: rows} = Postgrex.query!(conn, sql, [limit, @max_attempts])

    Enum.map(rows, fn [
                        id,
                        event,
                        topic,
                        payload,
                        apply,
                        message_id,
                        channel_id,
                        traceparent,
                        attempts
                      ] ->
      %{
        id: id,
        event: event,
        topic: topic,
        payload: decode(payload),
        apply: decode(apply),
        message_id: message_id,
        channel_id: channel_id,
        traceparent: traceparent,
        attempts: attempts
      }
    end)
  end

  defp decode(nil), do: nil
  defp decode(json), do: Jason.decode!(json)

  defp record(conn, {id, :ok}) do
    Postgrex.query!(
      conn,
      """
      UPDATE #{table()}
         SET published_at = clock_timestamp(), payload = NULL, apply = NULL,
             attempts = attempts + 1
       WHERE id = $1::text::uuid
      """,
      [id]
    )
  end

  defp record(conn, {id, {:retry, reason}}) do
    Postgrex.query!(
      conn,
      "UPDATE #{table()} SET last_error = $2 WHERE id = $1::text::uuid",
      [id, error_text(reason)]
    )
  end

  defp record(conn, {id, {:error, reason}}) do
    Postgrex.query!(
      conn,
      "UPDATE #{table()} SET attempts = attempts + 1, last_error = $2 WHERE id = $1::text::uuid",
      [id, error_text(reason)]
    )
  end

  defp error_text(reason), do: reason |> Messaging.Log.reason() |> String.slice(0, 500)
end
