defmodule Messaging.Events.LocalBroadcaster do
  @behaviour Messaging.Events.Broadcaster

  @impl true
  def publish(topic, event, payload) do
    MessagingWeb.Endpoint.broadcast!(topic, event, payload)
  end
end
