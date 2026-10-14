defmodule Messaging.Events.LocalBroadcaster do
  @behaviour Messaging.Events.Broadcaster

  @impl true
  def publish(topic, event, payload) do
    MessagingWeb.Endpoint.broadcast!(topic, event, payload)
  end

  @impl true
  def publish_many(events) do
    Enum.each(events, fn {topic, event, payload} -> publish(topic, event, payload) end)
  end
end
