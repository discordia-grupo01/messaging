defmodule Messaging.Chat.Repo do
  @callback insert_message(doc :: map()) :: {:ok, map()} | {:error, term()}
  @callback list_messages(channel_id :: String.t(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}
  @callback update_message(
              id :: String.t(),
              channel_id :: String.t(),
              user_id :: String.t(),
              content :: String.t(),
              edited_at :: DateTime.t()
            ) :: {:ok, map() | nil} | {:error, term()}
  @callback delete_message(
              id :: String.t(),
              channel_id :: String.t(),
              deleted_at :: DateTime.t()
            ) :: {:ok, map() | nil} | {:error, term()}
  @callback get_message(id :: String.t()) :: map() | nil | {:error, term()}
  @callback list_changes(channel_id :: String.t(), since :: DateTime.t(), limit :: pos_integer()) ::
              {:ok, [map()]} | {:error, term()}
  @callback get_channel(channel_id :: String.t()) :: map() | nil | {:error, term()}
  @callback upsert_channel(doc :: map()) :: :ok | {:error, term()}
  @callback delete_channel(channel_id :: String.t()) :: :ok | {:error, term()}
  @callback delete_server_data(server_id :: String.t(), channel_ids :: [String.t()]) ::
              :ok | {:error, term()}
  @callback ping() :: :ok | {:error, term()}
  @callback ensure_indexes() :: :ok | {:error, term()}
end
