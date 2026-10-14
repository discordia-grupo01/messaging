defmodule Messaging.Events.EventPublisher do
  @callback publish_event(
              id :: String.t(),
              topic :: String.t(),
              event :: String.t(),
              payload :: map()
            ) :: :ok | {:error, term()}

  @spec publish_event(String.t(), String.t(), String.t(), map()) :: :ok | {:error, term()}
  def publish_event(id, topic, event, payload),
    do: impl().publish_event(id, topic, event, payload)

  defp impl,
    do: Application.get_env(:messaging, :event_publisher, Messaging.Events.BroadcastPublisher)
end
