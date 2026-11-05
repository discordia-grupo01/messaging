defmodule Messaging.Chat.Repo do
  @spec impl() :: module()
  def impl, do: Application.get_env(:messaging, :chat_repo, Messaging.Chat.Repo.Mongo)

  @callback insert_message(doc :: map()) :: {:ok, map()} | {:error, term()}
  @callback list_messages(channel_id :: String.t(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}
  @callback search_messages(channel_ids :: [String.t()], opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}
  @callback count_search_matches(
              channel_ids :: [String.t()],
              opts :: keyword(),
              limit :: pos_integer()
            ) :: {:ok, non_neg_integer()} | {:error, term()}
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
  @callback upsert_message(doc :: map()) :: :ok | {:error, term()}
  @callback apply_message_update(
              id :: String.t(),
              channel_id :: String.t(),
              fields :: map()
            ) :: :ok | {:error, term()}
  @callback list_changes(channel_id :: String.t(), since :: DateTime.t(), limit :: pos_integer()) ::
              {:ok, [map()]} | {:error, term()}
  @callback get_messages(ids :: [String.t()]) :: {:ok, [map()]} | {:error, term()}
  @callback add_reaction(doc :: map()) :: {:ok, :added | :unchanged} | {:error, term()}
  @callback remove_reaction(id :: String.t()) :: {:ok, :removed | :unchanged} | {:error, term()}
  @callback count_reactions(message_id :: String.t(), emoji :: String.t()) ::
              {:ok, non_neg_integer()} | {:error, term()}
  @callback reaction_emojis(message_id :: String.t()) :: {:ok, [String.t()]} | {:error, term()}
  @callback list_reactions(message_ids :: [String.t()]) :: {:ok, [map()]} | {:error, term()}
  @callback delete_reactions(message_id :: String.t()) :: :ok | {:error, term()}
  @callback touch_message(id :: String.t(), at :: DateTime.t()) :: :ok | {:error, term()}
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
  @callback list_text_channel_ids(server_id :: String.t()) ::
              {:ok, [String.t()]} | {:error, term()}
  @callback get_channel(channel_id :: String.t()) :: map() | nil | {:error, term()}
  @callback upsert_channel(doc :: map()) :: :ok | {:error, term()}
  @callback delete_channel(channel_id :: String.t()) :: :ok | {:error, term()}
  @callback delete_server_data(server_id :: String.t(), channel_ids :: [String.t()]) ::
              :ok | {:error, term()}
  @callback apply_server_owner(
              server_id :: String.t(),
              owner_id :: String.t(),
              at :: DateTime.t()
            ) :: {:ok, :applied | :stale} | {:error, term()}
  @callback apply_role(
              server_id :: String.t(),
              role_id :: String.t(),
              permissions :: [String.t()],
              is_everyone :: boolean(),
              at :: DateTime.t()
            ) :: {:ok, :applied | :stale} | {:error, term()}
  @callback delete_role(server_id :: String.t(), role_id :: String.t(), at :: DateTime.t()) ::
              {:ok, :applied | :stale} | {:error, term()}
  @callback apply_member_roles(
              server_id :: String.t(),
              user_id :: String.t(),
              role_ids :: [String.t()],
              at :: DateTime.t()
            ) :: {:ok, :applied | :stale} | {:error, term()}
  @callback delete_member(server_id :: String.t(), user_id :: String.t(), at :: DateTime.t()) ::
              {:ok, :applied | :stale} | {:error, term()}
  @callback apply_channel_overrides(
              server_id :: String.t(),
              channel_id :: String.t(),
              overrides :: [map()],
              at :: DateTime.t()
            ) :: {:ok, :applied | :stale} | {:error, term()}
  @callback apply_word_filter(server_id :: String.t(), words :: [String.t()], at :: DateTime.t()) ::
              {:ok, :applied | :stale} | {:error, term()}
  @callback get_word_filter(server_id :: String.t()) :: {:ok, [String.t()]} | {:error, term()}
  @callback apply_profile(user_id :: String.t(), version :: pos_integer()) ::
              {:ok, :applied | :stale} | {:error, term()}
  @callback apply_suspension(user_id :: String.t(), suspended :: boolean(), version :: integer()) ::
              {:ok, :applied | :stale} | {:error, term()}
  @callback suspended?(user_id :: String.t()) :: boolean() | {:error, term()}
  @callback apply_server_suspension(
              server_id :: String.t(),
              suspended :: boolean(),
              version :: integer()
            ) :: {:ok, :applied | :stale} | {:error, term()}
  @callback server_suspended?(server_id :: String.t()) :: boolean() | {:error, term()}
  @callback apply_premium(user_id :: String.t(), active :: boolean(), version :: integer()) ::
              {:ok, :applied | :stale} | {:error, term()}
  @callback premium?(user_id :: String.t()) :: boolean() | {:error, term()}
  @callback apply_emoji_created(emoji :: map()) :: :ok | {:error, term()}
  @callback apply_emoji_deleted(emoji :: map()) :: :ok | {:error, term()}
  @callback get_custom_emojis(ids :: [String.t()]) :: {:ok, [map()]} | {:error, term()}
  @callback get_server_owner(server_id :: String.t()) ::
              String.t() | nil | {:error, term()}
  @callback get_member(server_id :: String.t(), user_id :: String.t()) ::
              map() | nil | {:error, term()}
  @callback get_members(server_id :: String.t(), user_ids :: [String.t()]) ::
              {:ok, [map()]} | {:error, term()}
  @callback list_members(server_id :: String.t()) :: {:ok, [map()]} | {:error, term()}
  @callback list_roles(server_id :: String.t()) :: {:ok, [map()]} | {:error, term()}
  @callback get_channel_overrides(channel_id :: String.t()) ::
              {:ok, [map()]} | {:error, term()}
  @callback list_channel_overrides(channel_ids :: [String.t()]) ::
              {:ok, %{String.t() => [map()]}} | {:error, term()}
  @callback user_known?(user_id :: String.t()) :: boolean() | {:error, term()}
  @callback insert_attachment(doc :: map()) :: :ok | {:error, term()}
  @callback count_pending_attachments(user_id :: String.t()) ::
              {:ok, non_neg_integer()} | {:error, term()}
  @callback claim_attachments(
              ids :: [String.t()],
              user_id :: String.t(),
              channel_id :: String.t(),
              message_id :: String.t()
            ) :: {:ok, [map()]} | {:error, :invalid_attachment | term()}
  @callback release_attachments(message_id :: String.t()) :: :ok | {:error, term()}
  @callback orphan_message_attachments(message_id :: String.t(), at :: DateTime.t()) ::
              :ok | {:error, term()}
  @callback orphan_deleted_message_attachments(at :: DateTime.t(), limit :: pos_integer()) ::
              {:ok, non_neg_integer()} | {:error, term()}
  @callback list_cleanable_attachments(pending_before :: DateTime.t(), limit :: pos_integer()) ::
              {:ok, [map()]} | {:error, term()}
  @callback delete_attachments(ids :: [String.t()]) :: :ok | {:error, term()}
  @callback ping() :: :ok | {:error, term()}
  @callback ensure_indexes() :: :ok | {:error, term()}
end
