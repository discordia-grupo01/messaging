defmodule Messaging.Events.Broadcaster do
  @callback publish(event :: String.t(), payload :: map()) :: :ok | {:error, term()}

  @spec publish(String.t(), map()) :: :ok | {:error, term()}
  def publish(event, payload), do: impl().publish(event, payload)

  defp impl,
    do: Application.get_env(:messaging, :broadcaster, Messaging.Events.BroadcastPublisher)
end
