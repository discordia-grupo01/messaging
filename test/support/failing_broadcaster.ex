defmodule Messaging.FailingBroadcaster do
  @behaviour Messaging.Events.Broadcaster

  @impl true
  def publish(_topic, _event, _payload), do: {:error, :not_connected}
end
