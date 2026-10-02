defmodule Messaging.Auth.TicketStore do
  @callback put(doc :: map()) :: :ok | {:error, term()}
  @callback take(id :: String.t()) :: {:ok, map() | nil} | {:error, term()}
end
