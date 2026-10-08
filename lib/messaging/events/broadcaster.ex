defmodule Messaging.Events.Broadcaster do
  @callback publish(topic :: String.t(), event :: String.t(), payload :: map()) ::
              :ok | {:error, term()}

  @spec publish(String.t(), map()) :: :ok | {:error, term()}
  def publish(event, %{"channel_id" => channel_id} = payload),
    do: publish_to("channel:" <> channel_id, event, payload)

  @spec publish_to(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def publish_to(topic, event, payload), do: impl().publish(topic, event, payload)

  defp impl,
    do: Application.get_env(:messaging, :broadcaster, Messaging.Events.BroadcastPublisher)
end
