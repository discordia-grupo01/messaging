defmodule Messaging.Chat.Repo do
  @callback insert_message(doc :: map()) :: {:ok, map()} | {:error, term()}
  @callback list_messages(channel_id :: String.t(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}
  @callback get_message(id :: String.t()) :: map() | nil | {:error, term()}
  @callback get_channel(channel_id :: String.t()) :: map() | nil | {:error, term()}
  @callback upsert_channel(doc :: map()) :: :ok | {:error, term()}
  @callback delete_channel(channel_id :: String.t()) :: :ok | {:error, term()}
  @callback ping() :: :ok | {:error, term()}
end
