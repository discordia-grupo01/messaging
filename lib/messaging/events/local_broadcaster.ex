defmodule Messaging.Events.LocalBroadcaster do
  @behaviour Messaging.Events.Broadcaster

  @impl true
  def publish(%{"channel_id" => channel_id} = payload) do
    MessagingWeb.Endpoint.broadcast!("channel:" <> channel_id, "new_message", payload)
  end
end
