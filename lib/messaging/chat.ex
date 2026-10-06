defmodule Messaging.Chat do
  alias Messaging.Chat.{
    Access,
    Blocks,
    ChannelCache,
    Conversation,
    Mentions,
    MentionsClient,
    Message,
    UserMention,
    UsersClient
  }

  alias Messaging.Events.MentionNotifier
  alias Messaging.UUID

  require Logger

  @max_message_length 2_000
  @default_page_limit 50
  @max_page_limit 100
  @max_changes 200
  @clock_skew_ms 5_000

  def max_message_length, do: @max_message_length
  def max_page_limit, do: @max_page_limit

  defp repo, do: Application.get_env(:messaging, :chat_repo, Messaging.Chat.Repo.Mongo)

  @type send_message_params :: %{
          channel_id: String.t(),
          user_id: String.t(),
          content: String.t(),
          raw_jwt: String.t()
        }

  @spec send_message(send_message_params()) ::
          {:ok, Message.t()} | {:error, MessagingWeb.ApiError.reason()}
  def send_message(%{channel_id: channel_id, user_id: user_id, content: content, raw_jwt: raw_jwt}) do
    with {:ok, channel} <- fetch_text_channel(channel_id),
         {:ok, trimmed} <- validate_content(content),
         {:ok, true} <- check_permission(channel, user_id, raw_jwt),
         {:ok, mentions} <- resolve_mentions(channel, trimmed, raw_jwt),
         {:ok, message} <- persist_message(channel, user_id, trimmed, mentions) do
      record_mentions(message, mentions.recipient_ids)
      {:ok, message}
    else
      {:ok, false} -> {:error, :forbidden}
      {:error, _reason} = error -> error
    end
  end

  @type edit_message_params :: %{
          channel_id: String.t(),
          message_id: term(),
          user_id: String.t(),
          content: String.t(),
          raw_jwt: String.t()
        }

  @spec edit_message(edit_message_params()) ::
          {:ok, Message.t(), :updated | :unchanged} | {:error, MessagingWeb.ApiError.reason()}
  def edit_message(%{
        channel_id: channel_id,
        message_id: message_id,
        user_id: user_id,
        content: content,
        raw_jwt: raw_jwt
      }) do
    with {:ok, channel} <- fetch_channel(channel_id),
         {:ok, true} <- check_permission(channel, user_id, raw_jwt),
         {:ok, message} <- fetch_message(channel_id, message_id),
         :ok <- require_author(message, user_id),
         {:ok, trimmed} <- validate_content(content) do
      apply_edit(channel, message, trimmed, raw_jwt)
    else
      {:ok, false} -> {:error, :forbidden}
      {:error, _reason} = error -> error
    end
  end

  @type delete_message_params :: %{
          channel_id: String.t(),
          message_id: term(),
          user_id: String.t(),
          raw_jwt: String.t()
        }

  @spec delete_message(delete_message_params()) ::
          {:ok, Message.t()} | {:error, MessagingWeb.ApiError.reason()}
  def delete_message(%{
        channel_id: channel_id,
        message_id: message_id,
        user_id: user_id,
        raw_jwt: raw_jwt
      }) do
    with {:ok, channel} <- fetch_channel(channel_id),
         {:ok, true} <- Access.for_channel(channel).can_delete?(channel, user_id, raw_jwt),
         {:ok, message} <- fetch_message(channel_id, message_id),
         :ok <- authorize_delete(channel, message, user_id, raw_jwt) do
      apply_delete(message, user_id)
    else
      {:ok, false} -> {:error, :forbidden}
      {:error, _reason} = error -> error
    end
  end

  @type send_direct_params :: %{
          sender_id: String.t(),
          recipient_id: term(),
          content: String.t(),
          raw_jwt: String.t()
        }

  @spec send_direct_message(send_direct_params()) ::
          {:ok, ChannelCache.t(), Message.t()} | {:error, MessagingWeb.ApiError.reason()}
  def send_direct_message(%{
        sender_id: sender_id,
        recipient_id: recipient_id,
        content: content,
        raw_jwt: raw_jwt
      }) do
    with :ok <- validate_recipient(sender_id, recipient_id),
         {:ok, trimmed} <- validate_content(content),
         :ok <- Blocks.check_contact(sender_id, recipient_id),
         {:ok, channel} <- ensure_conversation(sender_id, recipient_id, raw_jwt),
         {:ok, message} <- persist_message(channel, sender_id, trimmed) do
      record_last_message(channel, message)
      {:ok, channel, message}
    end
  end

  @spec list_conversations(String.t(), keyword()) ::
          {:ok, [Conversation.t()]} | {:error, term()}
  def list_conversations(user_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit) |> clamp_limit()

    with {:ok, docs} <- repo().list_conversations(user_id, limit),
         {:ok, last_messages} <- fetch_last_messages(docs),
         {:ok, blocked} <- Blocks.blocked_among(user_id, partner_ids(docs, user_id)) do
      {:ok,
       Enum.map(docs, fn doc ->
         conversation = Conversation.from_doc(doc)

         %{
           conversation
           | last_message: Map.get(last_messages, doc["last_message_id"]),
             blocked_by_me:
               MapSet.member?(blocked, Conversation.partner_id(conversation, user_id))
         }
       end)}
    end
  end

  @spec mark_read(String.t(), String.t()) :: :ok | {:error, term()}
  def mark_read(conversation_id, user_id) do
    case repo().get_channel(conversation_id) do
      %{"kind" => "dm", "participants" => participants} = doc ->
        if user_id in participants,
          do: mark_read_up_to(doc, user_id),
          else: {:error, :channel_not_found}

      {:error, _reason} = error ->
        error

      _other ->
        {:error, :channel_not_found}
    end
  end

  @spec list_messages(String.t(), keyword()) ::
          {:ok, [Message.t()], String.t() | nil} | {:error, atom()}
  def list_messages(channel_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit) |> clamp_limit()
    before_id = Keyword.get(opts, :before)
    after_id = Keyword.get(opts, :after)

    with :ok <- exclusive_cursors(before_id, after_id),
         {:ok, before_pos} <- resolve_cursor(channel_id, before_id),
         {:ok, after_pos} <- resolve_cursor(channel_id, after_id),
         {:ok, docs} <-
           repo().list_messages(channel_id,
             before: before_pos,
             after: after_pos,
             limit: limit + 1
           ) do
      build_page(docs, limit, direction(after_id))
    end
  end

  @spec list_changes(String.t(), DateTime.t()) ::
          {:ok, [Message.t()], [String.t()]} | {:error, :too_many_changes | term()}
  def list_changes(channel_id, %DateTime{} = since) do
    from = DateTime.add(since, -@clock_skew_ms, :millisecond)

    case repo().list_changes(channel_id, from, @max_changes + 1) do
      {:ok, docs} when length(docs) > @max_changes -> {:error, :too_many_changes}
      {:ok, docs} -> split_changes(Enum.map(docs, &Message.from_doc/1))
      {:error, _reason} = error -> error
    end
  end

  defp split_changes(messages) do
    {deleted, edited} = Enum.split_with(messages, &(&1.deleted_at != nil))
    {:ok, edited, Enum.map(deleted, & &1.id)}
  end

  @spec server_time() :: String.t()
  def server_time,
    do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> Message.iso8601_z()

  @spec channel_exists?(String.t()) :: {:ok, ChannelCache.t()} | {:error, atom()}
  def channel_exists?(channel_id), do: fetch_channel(channel_id)

  @spec can_view_channel?(ChannelCache.t(), String.t(), String.t()) ::
          {:ok, boolean()} | {:error, term()}
  def can_view_channel?(%ChannelCache{} = channel, user_id, raw_jwt),
    do: Access.for_channel(channel).can_view?(channel, user_id, raw_jwt)

  @spec upsert_channel(ChannelCache.t()) :: :ok | {:error, term()}
  def upsert_channel(%ChannelCache{} = channel) do
    repo().upsert_channel(%{
      "_id" => channel.channel_id,
      "server_id" => channel.server_id,
      "name" => channel.name,
      "kind" => channel.kind
    })
  end

  @spec delete_channel(String.t()) :: :ok | {:error, term()}
  def delete_channel(channel_id), do: repo().delete_channel(channel_id)

  @spec delete_server_data(String.t(), [String.t()]) :: :ok | {:error, term()}
  def delete_server_data(server_id, channel_ids) when is_list(channel_ids),
    do: repo().delete_server_data(server_id, channel_ids)

  @spec list_mentions(String.t(), keyword()) :: {:ok, [UserMention.t()]} | {:error, term()}
  def list_mentions(user_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit) |> clamp_limit()

    with {:ok, docs} <- repo().list_unread_mentions(user_id, limit),
         mentions = Enum.map(docs, &UserMention.from_doc/1),
         {:ok, messages} <- fetch_messages(Enum.map(mentions, & &1.message_id)) do
      {:ok, Enum.map(mentions, &%{&1 | message: Map.get(messages, &1.message_id)})}
    end
  end

  @doc "Marks as read every mention of the user in a channel (opening it)."
  @spec mark_mentions_read(String.t(), String.t()) :: :ok | {:error, term()}
  def mark_mentions_read(channel_id, user_id) do
    with {:ok, _channel} <- fetch_channel(channel_id) do
      now = DateTime.utc_now() |> DateTime.truncate(:millisecond)
      repo().mark_mentions_read(user_id, channel_id, now)
    end
  end

  @spec delete_member_mentions(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_member_mentions(server_id, user_id),
    do: repo().delete_member_mentions(server_id, user_id)

  @spec mongo_ready?() :: boolean()
  def mongo_ready?, do: repo().ping() == :ok

  defp fetch_channel(channel_id) do
    case repo().get_channel(channel_id) do
      nil -> {:error, :channel_not_found}
      {:error, _reason} = error -> error
      doc -> validate_messageable(ChannelCache.from_doc(doc))
    end
  end

  defp fetch_text_channel(channel_id) do
    with {:ok, channel} <- fetch_channel(channel_id) do
      if ChannelCache.text_channel?(channel),
        do: {:ok, channel},
        else: {:error, :channel_not_text}
    end
  end

  defp validate_messageable(%ChannelCache{} = channel) do
    if ChannelCache.messageable?(channel), do: {:ok, channel}, else: {:error, :channel_not_text}
  end

  defp validate_recipient(sender_id, sender_id), do: {:error, :cannot_message_self}

  defp validate_recipient(_sender_id, recipient_id) do
    if Conversation.valid_user_id?(recipient_id), do: :ok, else: {:error, :recipient_not_found}
  end

  defp ensure_conversation(sender_id, recipient_id, raw_jwt) do
    conversation_id = Conversation.id(sender_id, recipient_id)

    case repo().get_channel(conversation_id) do
      %{} = doc -> {:ok, ChannelCache.from_doc(doc)}
      nil -> create_conversation(sender_id, recipient_id, raw_jwt)
      {:error, _reason} = error -> error
    end
  end

  defp create_conversation(sender_id, recipient_id, raw_jwt) do
    doc = Conversation.new_doc(sender_id, recipient_id, DateTime.utc_now())

    with :ok <- verify_recipient(recipient_id, raw_jwt),
         :ok <- repo().ensure_conversation(doc) do
      Logger.info(
        "messaging: conversation_created conversation_id=#{doc["_id"]} user_id=#{sender_id}"
      )

      {:ok, ChannelCache.from_doc(doc)}
    end
  end

  defp verify_recipient(recipient_id, raw_jwt) do
    case UsersClient.verify(recipient_id, raw_jwt) do
      :ok -> :ok
      {:error, :not_found} -> {:error, :recipient_not_found}
      {:error, :unavailable} -> {:error, :users_unavailable}
    end
  end

  defp record_last_message(%ChannelCache{channel_id: channel_id}, %Message{} = message) do
    case repo().record_last_message(channel_id, message.id, message.user_id, message.inserted_at) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "messaging: conversation_update_failed conversation_id=#{channel_id} reason=#{inspect(reason)}"
        )
    end
  end

  defp partner_ids(docs, user_id) do
    Enum.map(docs, &Conversation.partner_id(Conversation.from_doc(&1), user_id))
  end

  defp fetch_last_messages(docs),
    do: fetch_messages(for(%{"last_message_id" => id} when is_binary(id) <- docs, do: id))

  defp fetch_messages([]), do: {:ok, %{}}

  defp fetch_messages(ids) do
    with {:ok, message_docs} <- repo().get_messages(ids) do
      {:ok, Map.new(message_docs, &{&1["_id"], Message.from_doc(&1)})}
    end
  end

  defp mark_read_up_to(%{"_id" => id} = doc, user_id) do
    case Map.get(doc, "last_message_at") do
      %DateTime{} = at -> repo().mark_read(id, user_id, at)
      _none -> :ok
    end
  end

  defp validate_content(content) do
    trimmed = content |> to_string() |> String.trim()

    cond do
      trimmed == "" -> {:error, :empty_content}
      String.length(trimmed) > @max_message_length -> {:error, :message_too_long}
      true -> {:ok, trimmed}
    end
  end

  defp check_permission(%ChannelCache{} = channel, user_id, raw_jwt),
    do: Access.for_channel(channel).can_post?(channel, user_id, raw_jwt)

  defp resolve_mentions(%ChannelCache{kind: "dm"}, _content, _raw_jwt), do: {:ok, Mentions.none()}

  defp resolve_mentions(%ChannelCache{server_id: nil}, _content, _raw_jwt),
    do: {:ok, Mentions.none()}

  defp resolve_mentions(%ChannelCache{} = channel, content, raw_jwt) do
    query = Mentions.parse(content)

    if Mentions.any?(query),
      do: MentionsClient.resolve(channel.server_id, channel.channel_id, query, raw_jwt),
      else: {:ok, Mentions.none()}
  end

  defp record_mentions(%Message{}, []), do: :ok

  defp record_mentions(%Message{} = message, recipient_ids) do
    docs = Enum.map(recipient_ids, &UserMention.new_doc(message, &1))

    case repo().insert_mentions(docs) do
      {:ok, new_ids} ->
        MentionNotifier.notify(message, new_ids)

      {:error, reason} ->
        Logger.warning(
          "messaging: mentions_insert_failed message_id=#{message.id} reason=#{inspect(reason)}"
        )

        MentionNotifier.notify(message, recipient_ids)
    end
  end

  # After an edit: forget the users the message no longer reaches, notify the
  # ones it reaches for the first time.
  defp sync_mentions(%Message{} = before, %Message{} = after_edit, recipient_ids) do
    if Message.mentions?(before) do
      case repo().delete_mentions(after_edit.id, recipient_ids) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "messaging: mentions_delete_failed message_id=#{after_edit.id} reason=#{inspect(reason)}"
          )
      end
    end

    record_mentions(after_edit, recipient_ids)
  end

  defp persist_message(%ChannelCache{} = channel, user_id, content, mentions \\ Mentions.none()) do
    message = %Message{
      id: UUID.generate_v7(),
      channel_id: channel.channel_id,
      server_id: channel.server_id,
      user_id: user_id,
      content: content,
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:millisecond),
      mentions: mentions.user_ids,
      mention_roles: mentions.role_ids,
      mention_everyone: mentions.everyone
    }

    doc =
      %{
        "_id" => message.id,
        "channel_id" => message.channel_id,
        "server_id" => message.server_id,
        "user_id" => message.user_id,
        "content" => message.content,
        "inserted_at" => message.inserted_at
      }
      |> with_mention_fields(message, mentions)

    case repo().insert_message(doc) do
      {:ok, _doc} ->
        Logger.info(
          "messaging: message_sent channel_id=#{message.channel_id} user_id=#{user_id} message_id=#{message.id}"
        )

        {:ok, message}

      {:error, reason} = error ->
        Logger.warning(
          "messaging: message_insert_failed channel_id=#{message.channel_id} reason=#{inspect(reason)}"
        )

        error
    end
  end

  # Only messages with mentions carry the fields, so the rest stay as before.
  defp with_mention_fields(doc, message, mentions) do
    if Message.mentions?(message),
      do: Map.merge(doc, Mentions.message_fields(mentions)),
      else: doc
  end

  defp exclusive_cursors(nil, _after_id), do: :ok
  defp exclusive_cursors(_before_id, nil), do: :ok
  defp exclusive_cursors(_before_id, _after_id), do: {:error, :invalid_cursor}

  defp fetch_message(channel_id, message_id) when is_binary(message_id) do
    case repo().get_message(message_id) do
      %{"channel_id" => ^channel_id} = doc -> live_message(Message.from_doc(doc))
      _other -> {:error, :message_not_found}
    end
  end

  defp fetch_message(_channel_id, _message_id), do: {:error, :message_not_found}

  defp live_message(%Message{deleted_at: nil} = message), do: {:ok, message}
  defp live_message(%Message{}), do: {:error, :message_not_found}

  defp require_author(%Message{user_id: user_id}, user_id), do: :ok
  defp require_author(%Message{}, _user_id), do: {:error, :not_message_author}

  defp authorize_delete(_channel, %Message{user_id: user_id}, user_id, _raw_jwt), do: :ok

  defp authorize_delete(%ChannelCache{} = channel, %Message{}, user_id, raw_jwt) do
    case Access.for_channel(channel).can_moderate?(channel, user_id, raw_jwt) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :message_delete_denied}
      {:error, _reason} = error -> error
    end
  end

  defp apply_delete(%Message{} = message, actor_id) do
    deleted_at = DateTime.utc_now() |> DateTime.truncate(:millisecond)

    case repo().delete_message(message.id, message.channel_id, deleted_at) do
      {:ok, nil} ->
        {:error, :message_not_found}

      {:ok, doc} ->
        Logger.info(
          "messaging: message_deleted channel_id=#{message.channel_id} actor_id=#{actor_id} author_id=#{message.user_id} message_id=#{message.id}"
        )

        forget_mentions(message)
        {:ok, Message.from_doc(doc)}

      {:error, reason} = error ->
        Logger.warning(
          "messaging: message_delete_failed channel_id=#{message.channel_id} reason=#{inspect(reason)}"
        )

        error
    end
  end

  # A deleted message must not keep notifications that point at it.
  defp forget_mentions(%Message{} = message) do
    if Message.mentions?(message) do
      case repo().delete_mentions(message.id, []) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "messaging: mentions_delete_failed message_id=#{message.id} reason=#{inspect(reason)}"
          )
      end
    end
  end

  defp apply_edit(_channel, %Message{content: content} = message, content, _raw_jwt),
    do: {:ok, message, :unchanged}

  defp apply_edit(%ChannelCache{} = channel, %Message{} = message, new_content, raw_jwt) do
    with {:ok, mentions} <- resolve_mentions(channel, new_content, raw_jwt) do
      update_content(message, new_content, mentions)
    end
  end

  defp update_content(%Message{} = message, new_content, mentions) do
    edited_at = DateTime.utc_now() |> DateTime.truncate(:millisecond)

    case repo().update_message(
           message.id,
           message.channel_id,
           message.user_id,
           new_content,
           edited_at,
           Mentions.message_fields(mentions)
         ) do
      {:ok, nil} ->
        {:error, :message_not_found}

      {:ok, doc} ->
        Logger.info(
          "messaging: message_edited channel_id=#{message.channel_id} user_id=#{message.user_id} message_id=#{message.id}"
        )

        edited = Message.from_doc(doc)
        sync_mentions(message, edited, mentions.recipient_ids)
        {:ok, edited, :updated}

      {:error, reason} = error ->
        Logger.warning(
          "messaging: message_update_failed channel_id=#{message.channel_id} reason=#{inspect(reason)}"
        )

        error
    end
  end

  defp resolve_cursor(_channel_id, nil), do: {:ok, nil}

  defp resolve_cursor(channel_id, message_id) when is_binary(message_id) do
    case repo().get_message(message_id) do
      %{"channel_id" => ^channel_id, "inserted_at" => %DateTime{} = at} -> {:ok, {at, message_id}}
      _other -> {:error, :invalid_cursor}
    end
  end

  defp resolve_cursor(_channel_id, _message_id), do: {:error, :invalid_cursor}

  defp direction(nil), do: :backward
  defp direction(_after_id), do: :forward

  defp build_page(docs, limit, direction) do
    {page, rest} = Enum.split(docs, limit)
    messages = Enum.map(page, &Message.from_doc/1)
    next_cursor = if rest == [], do: nil, else: List.last(messages).id
    ordered = if direction == :backward, do: Enum.reverse(messages), else: messages
    {:ok, ordered, next_cursor}
  end

  defp clamp_limit(n) when is_integer(n) and n > 0 and n <= @max_page_limit, do: n
  defp clamp_limit(_other), do: @default_page_limit
end
