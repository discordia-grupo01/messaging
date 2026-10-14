defmodule Messaging.Outbox.Dispatcher do
  require Logger

  alias Messaging.Events.EventPublisher
  alias Messaging.Log
  alias Messaging.Outbox.{Applier, Store}

  @spec handle_batch([Store.pending()]) :: [{String.t(), Store.outcome()}]
  def handle_batch(rows) do
    {results, _halted} =
      Enum.map_reduce(rows, nil, fn
        row, nil ->
          outcome = handle(row)
          {{row.id, outcome}, halt_reason(outcome)}

        row, reason ->
          {{row.id, {:retry, reason}}, reason}
      end)

    results
  end

  @spec handle(Store.pending()) :: Store.outcome()
  def handle(row) do
    with :ok <- Applier.apply(row.apply),
         :ok <- EventPublisher.publish_event(row.id, row.topic, row.event, row.payload) do
      :ok
    else
      {:error, {:invalid, _detail} = reason} ->
        log_failure(row, reason)
        {:error, reason}

      {:error, reason} ->
        log_failure(row, reason)
        {:retry, reason}
    end
  end

  defp halt_reason({:retry, reason}), do: reason
  defp halt_reason(_outcome), do: nil

  defp log_failure(row, reason) do
    Logger.warning("outbox_event_failed",
      routing_key: row.event,
      message_id: row.message_id,
      attempts: row.attempts,
      reason: Log.reason(reason)
    )
  end
end
