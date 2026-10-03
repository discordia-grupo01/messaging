defmodule Messaging.Events.LocalBroadcaster do
  @behaviour Messaging.Events.Broadcaster

  @impl true
  def publish(event, %{"channel_id" => channel_id} = payload) do
    MessagingWeb.Endpoint.broadcast!("channel:" <> channel_id, event, payload)
  end
end
