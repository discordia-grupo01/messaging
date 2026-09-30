defmodule Messaging.Events.Broadcaster do
  @callback publish(payload :: map()) :: :ok | {:error, term()}
end
