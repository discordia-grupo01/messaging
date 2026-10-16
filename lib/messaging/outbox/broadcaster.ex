defmodule Messaging.Outbox.Broadcaster do
  @behaviour Messaging.Events.Broadcaster

  alias Messaging.Outbox

  @impl true
  def publish(topic, event, payload), do: publish_many([{topic, event, payload}])

  @impl true
  def publish_many(events) do
    events
    |> Enum.map(fn {topic, event, payload} ->
      %{
        event: event,
        topic: topic,
        payload: payload,
        message_id: message_key(payload),
        channel_id: payload["channel_id"]
      }
    end)
    |> Outbox.enqueue()
  end

  defp message_key(%{"message_id" => id}) when is_binary(id), do: id
  defp message_key(%{"message" => %{"id" => id}}) when is_binary(id), do: id
  defp message_key(%{"id" => id}) when is_binary(id), do: id
  defp message_key(_payload), do: nil
end
