defmodule Messaging.Chat.Repo do
  @spec impl() :: module()
  def impl, do: Application.get_env(:messaging, :chat_repo, Messaging.Chat.Repo.Mongo)

  @callback insert_message(doc :: map()) :: {:ok, map()} | {:error, term()}
  @callback list_messages(channel_id :: String.t(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}
  @callback update_message(
              id :: String.t(),
              channel_id :: String.t(),
              user_id :: String.t(),
              content :: String.t(),
              edited_at :: DateTime.t(),
              mention_fields :: map()
            ) :: {:ok, map() | nil} | {:error, term()}
  @callback delete_message(
              id :: String.t(),
              channel_id :: String.t(),
              deleted_at :: DateTime.t()
            ) :: {:ok, map() | nil} | {:error, term()}
  @callback get_message(id :: String.t()) :: map() | nil | {:error, term()}
  @callback list_changes(channel_id :: String.t(), since :: DateTime.t(), limit :: pos_integer()) ::
              {:ok, [map()]} | {:error, term()}
  @callback get_messages(ids :: [String.t()]) :: {:ok, [map()]} | {:error, term()}
  @callback ensure_conversation(doc :: map()) :: :ok | {:error, term()}
  @callback record_last_message(
              channel_id :: String.t(),
              message_id :: String.t(),
              user_id :: String.t(),
              at :: DateTime.t()
            ) :: :ok | {:error, term()}
  @callback list_conversations(user_id :: String.t(), limit :: pos_integer()) ::
              {:ok, [map()]} | {:error, term()}
  @callback mark_read(channel_id :: String.t(), user_id :: String.t(), at :: DateTime.t()) ::
              :ok | {:error, term()}
  @callback put_block(doc :: map()) :: :ok | {:error, term()}
  @callback delete_block(id :: String.t()) :: :ok | {:error, term()}
  @callback get_blocks(ids :: [String.t()]) :: {:ok, [map()]} | {:error, term()}
  @callback list_blocks(blocker_id :: String.t(), limit :: pos_integer()) ::
              {:ok, [map()]} | {:error, term()}
  @callback insert_mentions(docs :: [map()]) :: {:ok, [String.t()]} | {:error, term()}
  @callback delete_mentions(message_id :: String.t(), keep_user_ids :: [String.t()]) ::
              :ok | {:error, term()}
  @callback list_unread_mentions(user_id :: String.t(), limit :: pos_integer()) ::
              {:ok, [map()]} | {:error, term()}
  @callback mark_mentions_read(
              user_id :: String.t(),
              channel_id :: String.t(),
              at :: DateTime.t()
            ) ::
              :ok | {:error, term()}
  @callback delete_member_mentions(server_id :: String.t(), user_id :: String.t()) ::
              :ok | {:error, term()}
  @callback apply_clock(
              key :: String.t(),
              state :: String.t(),
              at :: DateTime.t(),
              expires_at :: DateTime.t() | nil
            ) :: {:ok, :applied | :stale} | {:error, term()}
  @callback get_clock(key :: String.t()) :: map() | nil | {:error, term()}
  @callback list_channel_ids(server_id :: String.t()) :: {:ok, [String.t()]} | {:error, term()}
  @callback get_channel(channel_id :: String.t()) :: map() | nil | {:error, term()}
  @callback upsert_channel(doc :: map()) :: :ok | {:error, term()}
  @callback delete_channel(channel_id :: String.t()) :: :ok | {:error, term()}
  @callback delete_server_data(server_id :: String.t(), channel_ids :: [String.t()]) ::
              :ok | {:error, term()}
  @callback ping() :: :ok | {:error, term()}
  @callback ensure_indexes() :: :ok | {:error, term()}
end
