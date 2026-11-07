defmodule Messaging.Chat do
  alias Messaging.Chat.{
    Access,
    Attachment,
    AttachmentCleaner,
    Blocks,
    ChannelCache,
    Conversation,
    MentionResolver,
    Mentions,
    Message,
    Reaction,
    Search,
    UserMention,
    WordFilter
  }

  alias Messaging.Chat.CustomEmoji
  alias Messaging.Events.{DomainEvent, MentionNotifier}
  alias Messaging.Log
  alias Messaging.Outbox
  alias Messaging.Outbox.Applier
  alias Messaging.Premium
  alias Messaging.ServerSuspension
  alias Messaging.Suspension
  alias Messaging.Storage
  alias Messaging.UUID

  require Logger

  @max_message_length 2_000
  @default_page_limit 50
  @max_page_limit 100
  @max_changes 200
  @max_lookup_ids 50
  @hidden_channel_errors [:channel_not_found, :channel_not_text, :server_suspended]
  @clock_skew_ms 5_000
  @message_namespace "6c1b7f0e-2d4a-4b8e-9f35-1a7e0c5d3b92"

  def max_message_length, do: @max_message_length
  def max_page_limit, do: @max_page_limit

  @spec authorize_private_voice(String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def authorize_private_voice(user_id, recipient_id, conversation_id) do
    with :ok <- Suspension.ensure_active(user_id),
         {:ok, channel} <- fetch_channel(conversation_id),
         true <- channel.server_id == nil,
         true <- user_id in channel.participants,
         true <- recipient_id in channel.participants,
         :ok <- Blocks.check_contact(user_id, recipient_id) do
      :ok
    else
      false -> {:error, :forbidden}
      {:error, :user_blocked} -> {:error, :forbidden}
      {:error, :dm_not_delivered} -> {:error, :forbidden}
      {:error, _reason} = error -> error
    end
  end

  defp repo, do: Application.get_env(:messaging, :chat_repo, Messaging.Chat.Repo.Mongo)

  @type send_message_params :: %{
          required(:channel_id) => String.t(),
          required(:user_id) => String.t(),
          required(:content) => String.t(),
          optional(:attachment_ids) => term(),
          optional(:client_id) => String.t() | nil
        }

  @spec send_message(send_message_params()) ::
          {:ok, Message.t()} | {:error, MessagingWeb.ApiError.reason()}
  def send_message(
        %{
          channel_id: channel_id,
          user_id: user_id,
          content: content
        } = params
      ) do
    with :ok <- Suspension.ensure_active(user_id),
         {:ok, channel} <- fetch_text_channel(channel_id),
         :ok <- ensure_not_muted(channel, user_id),
         {:ok, attachment_ids} <- validate_attachment_ids(Map.get(params, :attachment_ids)),
         {:ok, trimmed} <- validate_content(content, attachment_ids != []),
         {:ok, true} <- check_permission(channel, user_id),
         :ok <- check_word_filter(channel, trimmed),
         :ok <- CustomEmoji.authorize(user_id, CustomEmoji.tokens(trimmed), channel.server_id),
         {:ok, mentions} <- resolve_mentions(channel, trimmed, user_id),
         {:ok, message, outcome} <-
           persist_message(
             channel,
             user_id,
             trimmed,
             mentions,
             attachment_ids,
             Map.get(params, :client_id)
           ) do
      if outcome == :created, do: record_mentions(message, mentions.recipient_ids)
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
          content: String.t()
        }

  @spec edit_message(edit_message_params()) ::
          {:ok, Message.t(), :updated | :unchanged} | {:error, MessagingWeb.ApiError.reason()}
  def edit_message(%{
        channel_id: channel_id,
        message_id: message_id,
        user_id: user_id,
        content: content
      }) do
    with :ok <- Suspension.ensure_active(user_id),
         {:ok, channel} <- fetch_channel(channel_id),
         :ok <- ensure_not_muted(channel, user_id),
         {:ok, true} <- check_permission(channel, user_id),
         {:ok, message} <- fetch_message(channel_id, message_id),
         :ok <- require_author(message, user_id),
         {:ok, trimmed} <- validate_content(content, message.attachments != []) do
      apply_edit(channel, message, trimmed, user_id)
    else
      {:ok, false} -> {:error, :forbidden}
      {:error, _reason} = error -> error
    end
  end

  @type delete_message_params :: %{
          channel_id: String.t(),
          message_id: term(),
          user_id: String.t()
        }

  @spec delete_message(delete_message_params()) ::
          {:ok, Message.t()} | {:error, MessagingWeb.ApiError.reason()}
  def delete_message(%{
        channel_id: channel_id,
        message_id: message_id,
        user_id: user_id
      }) do
    with :ok <- Suspension.ensure_active(user_id),
         {:ok, channel} <- fetch_channel(channel_id),
         {:ok, true} <- Access.for_channel(channel).can_delete?(channel, user_id),
         {:ok, message} <- fetch_message(channel_id, message_id),
         :ok <- authorize_delete(channel, message, user_id) do
      apply_delete(message, user_id)
    else
      {:ok, false} -> {:error, :forbidden}
      {:error, _reason} = error -> error
    end
  end

  @type reaction_params :: %{
          channel_id: String.t(),
          message_id: term(),
          user_id: String.t(),
          emoji: term()
        }

  @type reaction_result :: %{
          message: Message.t(),
          emoji: String.t(),
          count: non_neg_integer(),
          changed: boolean()
        }

  @spec add_reaction(reaction_params()) ::
          {:ok, reaction_result()} | {:error, MessagingWeb.ApiError.reason()}
  def add_reaction(%{
        channel_id: channel_id,
        message_id: message_id,
        user_id: user_id,
        emoji: emoji
      }) do
    with :ok <- Suspension.ensure_active(user_id),
         {:ok, channel} <- fetch_channel(channel_id),
         :ok <- ensure_not_muted(channel, user_id),
         {:ok, emoji} <- Reaction.validate_emoji(emoji),
         {:ok, true} <- Access.for_channel(channel).can_react?(channel, user_id),
         :ok <- CustomEmoji.authorize(user_id, CustomEmoji.tokens(emoji), channel.server_id),
         {:ok, message} <- fetch_message(channel_id, message_id),
         :ok <- ensure_reaction_room(message, emoji),
         now = DateTime.utc_now() |> DateTime.truncate(:millisecond),
         {:ok, outcome} <- repo().add_reaction(Reaction.new_doc(message, emoji, user_id, now)) do
      reaction_result(message, emoji, outcome == :added, now)
    else
      {:ok, false} -> {:error, :forbidden}
      {:error, _reason} = error -> error
    end
  end

  @spec remove_reaction(reaction_params()) ::
          {:ok, reaction_result()} | {:error, MessagingWeb.ApiError.reason()}
  def remove_reaction(%{
        channel_id: channel_id,
        message_id: message_id,
        user_id: user_id,
        emoji: emoji
      }) do
    with :ok <- Suspension.ensure_active(user_id),
         {:ok, channel} <- fetch_channel(channel_id),
         {:ok, emoji} <- Reaction.validate_emoji(emoji),
         {:ok, true} <- Access.for_channel(channel).can_view?(channel, user_id),
         {:ok, message} <- fetch_message(channel_id, message_id),
         {:ok, outcome} <- repo().remove_reaction(Reaction.id(message.id, emoji, user_id)) do
      now = DateTime.utc_now() |> DateTime.truncate(:millisecond)
      reaction_result(message, emoji, outcome == :removed, now)
    else
      {:ok, false} -> {:error, :forbidden}
      {:error, _reason} = error -> error
    end
  end

  @spec reactions_for([Message.t()], String.t()) ::
          {:ok, %{String.t() => [Reaction.summary()]}} | {:error, term()}
  def reactions_for([], _viewer_id), do: {:ok, %{}}

  def reactions_for(messages, viewer_id) do
    with {:ok, docs} <- repo().list_reactions(Enum.map(messages, & &1.id)) do
      {:ok, Reaction.summarize(docs, viewer_id)}
    end
  end

  defp ensure_reaction_room(%Message{id: id}, emoji) do
    with {:ok, emojis} <- repo().reaction_emojis(id) do
      if emoji in emojis or length(emojis) < Reaction.max_per_message(),
        do: :ok,
        else: {:error, :too_many_reactions}
    end
  end

  defp reaction_result(%Message{} = message, emoji, changed, now) do
    with {:ok, count} <- repo().count_reactions(message.id, emoji) do
      if changed, do: touch_message(message, now)
      {:ok, %{message: message, emoji: emoji, count: count, changed: changed}}
    end
  end

  # Moves changed_at so a member reconnecting gets the message back in
  # changed_messages, with its current reactions.
  defp touch_message(%Message{} = message, now) do
    case repo().touch_message(message.id, now) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("message_touch_failed", message_id: message.id, reason: Log.reason(reason))
    end
  end

  @type send_direct_params :: %{
          required(:sender_id) => String.t(),
          required(:recipient_id) => term(),
          required(:content) => String.t(),
          optional(:attachment_ids) => term(),
          optional(:client_id) => String.t() | nil
        }

  @spec send_direct_message(send_direct_params()) ::
          {:ok, ChannelCache.t(), Message.t()} | {:error, MessagingWeb.ApiError.reason()}
  def send_direct_message(
        %{
          sender_id: sender_id,
          recipient_id: recipient_id,
          content: content
        } = params
      ) do
    with :ok <- Suspension.ensure_active(sender_id),
         :ok <- validate_recipient(sender_id, recipient_id),
         {:ok, attachment_ids} <- validate_attachment_ids(Map.get(params, :attachment_ids)),
         {:ok, trimmed} <- validate_content(content, attachment_ids != []),
         :ok <- Blocks.check_contact(sender_id, recipient_id),
         :ok <- CustomEmoji.authorize(sender_id, CustomEmoji.tokens(trimmed), nil),
         {:ok, channel} <- ensure_conversation(sender_id, recipient_id),
         {:ok, message, outcome} <-
           persist_message(
             channel,
             sender_id,
             trimmed,
             Mentions.none(),
             attachment_ids,
             Map.get(params, :client_id)
           ) do
      if outcome == :created, do: record_last_message(channel, message)
      {:ok, channel, message}
    end
  end

  @type upload_target :: {:channel, String.t()} | {:direct, term()}

  @spec prepare_upload(upload_target(), String.t()) ::
          {:ok, String.t()} | {:error, MessagingWeb.ApiError.reason()}
  def prepare_upload({:channel, channel_id}, user_id) do
    with {:ok, channel} <- fetch_text_channel(channel_id),
         :ok <- ensure_not_muted(channel, user_id),
         {:ok, true} <- check_permission(channel, user_id) do
      {:ok, channel.channel_id}
    else
      {:ok, false} -> {:error, :forbidden}
      {:error, _reason} = error -> error
    end
  end

  def prepare_upload({:direct, recipient_id}, user_id) do
    with :ok <- validate_recipient(user_id, recipient_id),
         :ok <- Blocks.check_contact(user_id, recipient_id),
         :ok <- verify_recipient(recipient_id) do
      {:ok, Conversation.id(user_id, recipient_id)}
    end
  end

  @spec max_upload_bytes(String.t(), upload_target()) :: pos_integer()
  def max_upload_bytes(user_id, {:channel, channel_id}),
    do: Attachment.max_bytes_for(upload_plan(user_id, channel_id))

  def max_upload_bytes(user_id, {:direct, _recipient_id}),
    do: Attachment.max_bytes_for(upload_plan(user_id, nil))

  # Premium is the highest limit, so the server's level is only read without it.
  # If a lookup fails the next plan down applies: it must not block normal uploads.
  defp upload_plan(user_id, channel_id) do
    case Premium.premium?(user_id) do
      {:ok, true} ->
        :premium

      {:ok, false} ->
        boost_plan(channel_id)

      {:error, reason} ->
        Logger.warning("premium_lookup_failed", reason: Log.reason(reason))
        boost_plan(channel_id)
    end
  end

  defp boost_plan(nil), do: :free

  defp boost_plan(channel_id) do
    with %{"server_id" => server_id} when is_binary(server_id) <- repo().get_channel(channel_id),
         level when is_integer(level) <- repo().server_boost_level(server_id) do
      if level >= Attachment.boosted_level(), do: :boosted, else: :free
    else
      {:error, reason} ->
        Logger.warning("server_boost_lookup_failed", reason: Log.reason(reason))
        :free

      _no_server ->
        :free
    end
  end

  @spec store_attachment(String.t(), String.t(), term(), binary()) ::
          {:ok, Attachment.t()} | {:error, MessagingWeb.ApiError.reason()}
  def store_attachment(channel_id, user_id, filename, binary) do
    with :ok <- Suspension.ensure_active(user_id),
         {:ok, detected} <- validate_upload(channel_id, user_id, binary),
         :ok <- ensure_pending_room(user_id) do
      id = UUID.generate_v7()

      with {:ok, %{url: url, path: path}} <-
             put_object(Attachment.object_key(channel_id, id), binary, detected.content_type) do
        attachment = %Attachment{
          id: id,
          channel_id: channel_id,
          user_id: user_id,
          name: Attachment.sanitize_name(filename, detected.extension),
          content_type: detected.content_type,
          size: byte_size(binary),
          path: path,
          url: url
        }

        save_attachment(attachment)
      end
    end
  end

  defp validate_upload(channel_id, user_id, binary) do
    if byte_size(binary) > Attachment.max_bytes() or Attachment.gif?(binary) do
      Attachment.validate(binary, upload_plan(user_id, channel_id))
    else
      Attachment.validate(binary)
    end
  end

  defp ensure_pending_room(user_id) do
    case repo().count_pending_attachments(user_id) do
      {:ok, count} ->
        if count < Attachment.max_pending_per_user(),
          do: :ok,
          else: {:error, :too_many_pending_attachments}

      {:error, _reason} = error ->
        error
    end
  end

  defp put_object(key, binary, content_type) do
    case Storage.put(key, binary, content_type) do
      {:ok, %{url: _url, path: _path}} = ok ->
        ok

      {:error, reason} ->
        Logger.error("attachment_upload_failed", reason: Log.reason(reason))
        {:error, :storage_unavailable}
    end
  end

  defp save_attachment(%Attachment{} = attachment) do
    uploaded_at = DateTime.utc_now() |> DateTime.truncate(:millisecond)

    case repo().insert_attachment(Attachment.to_doc(attachment, uploaded_at)) do
      :ok ->
        Logger.info("attachment_uploaded",
          channel_id: attachment.channel_id,
          user_id: attachment.user_id,
          attachment_id: attachment.id,
          content_type: attachment.content_type,
          size: attachment.size
        )

        {:ok, %{attachment | uploaded_at: uploaded_at}}

      {:error, reason} = error ->
        Logger.error("attachment_insert_failed", reason: Log.reason(reason))
        _ = Storage.delete([attachment.path])
        error
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

  @spec list_messages_around(String.t(), String.t(), keyword()) ::
          {:ok, [Message.t()], String.t() | nil, String.t() | nil} | {:error, atom()}
  def list_messages_around(channel_id, message_id, opts \\ []) do
    half = opts |> Keyword.get(:limit) |> clamp_limit() |> div(2) |> max(1)

    with {:ok, center} <- fetch_message(channel_id, message_id),
         position = {center.inserted_at, center.id},
         {:ok, older} <- repo().list_messages(channel_id, before: position, limit: half + 1),
         {:ok, newer} <- repo().list_messages(channel_id, after: position, limit: half + 1) do
      {older, more_older?} = take_side(older, half)
      {newer, more_newer?} = take_side(newer, half)
      messages = Enum.reverse(older) ++ [center | newer]
      older_cursor = if more_older?, do: hd(messages).id
      newer_cursor = if more_newer?, do: List.last(messages).id
      {:ok, messages, older_cursor, newer_cursor}
    end
  end

  @spec lookup_messages([String.t()], String.t()) :: {:ok, [Message.t()]} | {:error, term()}
  def lookup_messages([], _user_id), do: {:ok, []}

  def lookup_messages(ids, user_id) when length(ids) <= @max_lookup_ids do
    order = ids |> Enum.with_index() |> Map.new()

    with {:ok, docs} <- repo().get_messages(ids),
         messages = docs |> Enum.map(&Message.from_doc/1) |> Enum.filter(&is_nil(&1.deleted_at)),
         {:ok, viewable} <- viewable_channel_ids(messages, user_id) do
      visible = Enum.filter(messages, &MapSet.member?(viewable, &1.channel_id))
      {:ok, Enum.sort_by(visible, &Map.fetch!(order, &1.id))}
    end
  end

  def lookup_messages(_ids, _user_id), do: {:error, :invalid_payload}

  defp viewable_channel_ids(messages, user_id) do
    messages
    |> Enum.map(& &1.channel_id)
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, MapSet.new()}, fn channel_id, {:ok, viewable} ->
      case channel_viewable?(channel_id, user_id) do
        {:ok, true} -> {:cont, {:ok, MapSet.put(viewable, channel_id)}}
        {:ok, false} -> {:cont, {:ok, viewable}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp channel_viewable?(channel_id, user_id) do
    with {:ok, channel} <- fetch_channel(channel_id),
         {:ok, viewable?} <- can_view_channel?(channel, user_id) do
      {:ok, viewable?}
    else
      {:error, reason} when reason in @hidden_channel_errors -> {:ok, false}
      {:error, _reason} = error -> error
    end
  end

  @spec search_messages(Search.params()) :: {:ok, Search.page()} | {:error, term()}
  def search_messages(%{server_id: server_id} = params) when is_binary(server_id) do
    with :ok <- ServerSuspension.ensure_active(server_id), do: Search.run(params)
  end

  def search_messages(params), do: Search.run(params)

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

  @spec can_view_channel?(ChannelCache.t(), String.t()) :: {:ok, boolean()} | {:error, term()}
  def can_view_channel?(%ChannelCache{} = channel, user_id),
    do: Access.for_channel(channel).can_view?(channel, user_id)

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

  @spec list_custom_emojis([String.t()]) ::
          {:ok, [map()]} | {:error, MessagingWeb.ApiError.reason()}
  def list_custom_emojis(ids), do: CustomEmoji.list(ids)

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

  # Every operation on a channel resolves it here, so this is where a server
  # suspended by the platform staff is shut: reading, writing, reacting and
  # uploading all stop, for anyone. Direct messages have no server.
  defp fetch_channel(channel_id) do
    case repo().get_channel(channel_id) do
      nil ->
        {:error, :channel_not_found}

      {:error, _reason} = error ->
        error

      doc ->
        with {:ok, channel} <- validate_messageable(ChannelCache.from_doc(doc)),
             :ok <- ensure_server_active(channel) do
          {:ok, channel}
        end
    end
  end

  defp ensure_server_active(%ChannelCache{server_id: nil}), do: :ok

  defp ensure_server_active(%ChannelCache{server_id: server_id}),
    do: ServerSuspension.ensure_active(server_id)

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

  defp ensure_conversation(sender_id, recipient_id) do
    conversation_id = Conversation.id(sender_id, recipient_id)

    case repo().get_channel(conversation_id) do
      %{} = doc -> {:ok, ChannelCache.from_doc(doc)}
      nil -> create_conversation(sender_id, recipient_id)
      {:error, _reason} = error -> error
    end
  end

  defp create_conversation(sender_id, recipient_id) do
    doc = Conversation.new_doc(sender_id, recipient_id, DateTime.utc_now())

    with :ok <- verify_recipient(recipient_id),
         :ok <- repo().ensure_conversation(doc) do
      Logger.info("conversation_created", conversation_id: doc["_id"], user_id: sender_id)

      {:ok, ChannelCache.from_doc(doc)}
    end
  end

  defp verify_recipient(recipient_id) do
    case repo().user_known?(recipient_id) do
      true -> :ok
      false -> {:error, :recipient_not_found}
      {:error, _reason} -> {:error, :users_unavailable}
    end
  end

  defp record_last_message(%ChannelCache{channel_id: channel_id}, %Message{} = message) do
    case repo().record_last_message(channel_id, message.id, message.user_id, message.inserted_at) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("conversation_update_failed",
          conversation_id: channel_id,
          reason: Log.reason(reason)
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

  defp validate_attachment_ids(nil), do: {:ok, []}

  defp validate_attachment_ids(ids) when is_list(ids) do
    cond do
      not Enum.all?(ids, &(is_binary(&1) and &1 != "")) -> {:error, :invalid_attachment}
      length(Enum.uniq(ids)) > Attachment.max_per_message() -> {:error, :too_many_attachments}
      true -> {:ok, Enum.uniq(ids)}
    end
  end

  defp validate_attachment_ids(_other), do: {:error, :invalid_attachment}

  defp validate_content(content, allow_empty?) do
    trimmed = content |> to_string() |> String.trim()

    cond do
      trimmed == "" and allow_empty? -> {:ok, ""}
      trimmed == "" -> {:error, :empty_content}
      String.length(trimmed) > @max_message_length -> {:error, :message_too_long}
      true -> {:ok, trimmed}
    end
  end

  defp check_word_filter(%ChannelCache{server_id: nil}, _content), do: :ok

  defp check_word_filter(%ChannelCache{server_id: server_id}, content) do
    with {:ok, banned} <- repo().get_word_filter(server_id) do
      case WordFilter.matches(content, banned) do
        [] -> :ok
        words -> {:error, {:banned_word, words}}
      end
    end
  end

  defp check_permission(%ChannelCache{} = channel, user_id),
    do: Access.for_channel(channel).can_post?(channel, user_id)

  defp ensure_not_muted(%ChannelCache{server_id: nil}, _user_id), do: :ok

  defp ensure_not_muted(%ChannelCache{server_id: server_id}, user_id) do
    case repo().get_clock(member_mute_key(server_id, user_id)) do
      %{"state" => "muted", "expires_at" => %DateTime{} = expires_at} ->
        if DateTime.compare(expires_at, DateTime.utc_now()) == :gt,
          do: {:error, :member_muted},
          else: :ok

      _other ->
        :ok
    end
  end

  defp member_mute_key(server_id, user_id), do: "member_mute:#{server_id}:#{user_id}"

  defp resolve_mentions(%ChannelCache{kind: "dm"}, _content, _actor_id),
    do: {:ok, Mentions.none()}

  defp resolve_mentions(%ChannelCache{server_id: nil}, _content, _actor_id),
    do: {:ok, Mentions.none()}

  defp resolve_mentions(%ChannelCache{} = channel, content, actor_id) do
    query = Mentions.parse(content)

    if Mentions.any?(query),
      do: MentionResolver.resolve(channel, query, actor_id),
      else: {:ok, Mentions.none()}
  end

  defp record_mentions(%Message{}, []), do: :ok

  defp record_mentions(%Message{} = message, recipient_ids) do
    docs = Enum.map(recipient_ids, &UserMention.new_doc(message, &1))

    case repo().insert_mentions(docs) do
      {:ok, new_ids} ->
        MentionNotifier.notify(message, new_ids)

      {:error, reason} ->
        Logger.warning("mentions_insert_failed",
          message_id: message.id,
          reason: Log.reason(reason)
        )

        MentionNotifier.notify(message, recipient_ids)
    end
  end

  defp sync_mentions(%Message{} = before, %Message{} = after_edit, recipient_ids) do
    if Message.mentions?(before) do
      case repo().delete_mentions(after_edit.id, recipient_ids) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("mentions_delete_failed",
            message_id: after_edit.id,
            reason: Log.reason(reason)
          )
      end
    end

    record_mentions(after_edit, recipient_ids)
  end

  defp persist_message(
         %ChannelCache{} = channel,
         user_id,
         content,
         mentions,
         attachment_ids,
         client_id
       ) do
    id = message_id(channel.channel_id, user_id, client_id)

    with :none <- existing_message(id, client_id),
         {:ok, attachment_docs} <- claim_attachments(attachment_ids, user_id, channel, id) do
      message = %Message{
        id: id,
        channel_id: channel.channel_id,
        server_id: channel.server_id,
        user_id: user_id,
        content: content,
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:millisecond),
        client_id: client_id,
        mentions: mentions.user_ids,
        mention_roles: mentions.role_ids,
        mention_everyone: mentions.everyone,
        attachments: Enum.map(attachment_docs, &Attachment.embed/1)
      }

      case insert_message(message, mentions, attachment_ids, channel) do
        {:ok, message} -> {:ok, message, :created}
        {:duplicate, message} -> {:ok, message, :duplicate}
        {:error, _reason} = error -> error
      end
    else
      {:duplicate, message} -> {:ok, message, :duplicate}
      {:error, _reason} = error -> error
    end
  end

  # With a client id the message id is derived from it, so a retried send maps
  # to the same id: a later retry finds the stored message, and one racing the
  # original is stopped by the outbox, which enqueues each creation event once.
  defp message_id(_channel_id, _user_id, nil), do: UUID.generate_v7()

  defp message_id(channel_id, user_id, client_id),
    do: UUID.v5(@message_namespace, channel_id <> ":" <> user_id <> ":" <> client_id)

  defp existing_message(_id, nil), do: :none

  defp existing_message(id, _client_id) do
    case repo().get_message(id) do
      %{"_id" => ^id} = doc -> {:duplicate, Message.from_doc(doc)}
      _none -> :none
    end
  end

  defp claim_attachments([], _user_id, _channel, _message_id), do: {:ok, []}

  defp claim_attachments(ids, user_id, %ChannelCache{channel_id: channel_id}, message_id),
    do: repo().claim_attachments(ids, user_id, channel_id, message_id)

  defp insert_message(%Message{} = message, mentions, attachment_ids, %ChannelCache{} = channel) do
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
      |> with_attachment_field(message)
      |> with_client_id_field(message)

    case Outbox.enqueue(created_entries(message, doc, channel, mentions)) do
      :ok ->
        store_message(message, doc)

      :duplicate ->
        Logger.info("message_send_deduplicated",
          channel_id: message.channel_id,
          message_id: message.id
        )

        case existing_message(message.id, message.client_id) do
          {:duplicate, stored} -> {:duplicate, stored}
          :none -> {:duplicate, message}
        end

      {:error, reason} ->
        Logger.error("message_enqueue_failed",
          channel_id: message.channel_id,
          reason: Log.reason(reason)
        )

        if attachment_ids != [], do: repo().release_attachments(message.id)
        {:error, :messages_unavailable}
    end
  end

  defp store_message(%Message{} = message, doc) do
    case repo().insert_message(doc) do
      {:ok, _doc} ->
        :ok

      {:error, reason} ->
        Logger.warning("message_insert_deferred",
          channel_id: message.channel_id,
          message_id: message.id,
          reason: Log.reason(reason)
        )
    end

    Logger.info("message_sent",
      channel_id: message.channel_id,
      user_id: message.user_id,
      message_id: message.id,
      attachments: length(message.attachments)
    )

    {:ok, message}
  end

  defp created_entries(
         %Message{} = message,
         doc,
         %ChannelCache{} = channel,
         %Mentions{} = mentions
       ) do
    payload = Message.to_api(message)

    created = %{
      event: "new_message",
      topic: "channel:" <> message.channel_id,
      payload: payload,
      apply: %{"op" => "insert_message", "doc" => Applier.encode_dates(doc)},
      message_id: message.id,
      channel_id: message.channel_id
    }

    [created | direct_entries(channel, message, payload)] ++
      domain_entries(channel, message, mentions)
  end

  defp domain_entries(
         %ChannelCache{kind: "dm", participants: participants},
         %Message{} = message,
         _mentions
       ) do
    for recipient_id <- participants,
        recipient_id != message.user_id,
        do: DomainEvent.direct_message_created(message, recipient_id)
  end

  defp domain_entries(%ChannelCache{server_id: nil}, _message, _mentions), do: []

  defp domain_entries(%ChannelCache{} = channel, %Message{} = message, %Mentions{} = mentions),
    do: [DomainEvent.message_created(message, mentions.recipient_ids, channel.name)]

  defp direct_entries(
         %ChannelCache{kind: "dm", participants: participants} = channel,
         message,
         payload
       ) do
    for user_id <- participants do
      %{
        event: "new_dm",
        topic: "user:" <> user_id,
        payload: %{
          "conversation_id" => channel.channel_id,
          "partner_id" => Enum.find(participants, &(&1 != user_id)),
          "message" => payload
        },
        message_id: message.id,
        channel_id: message.channel_id
      }
    end
  end

  defp direct_entries(%ChannelCache{}, _message, _payload), do: []

  defp with_attachment_field(doc, %Message{attachments: []}), do: doc

  defp with_attachment_field(doc, %Message{attachments: attachments}),
    do: Map.put(doc, "attachments", attachments)

  defp with_client_id_field(doc, %Message{client_id: nil}), do: doc
  defp with_client_id_field(doc, %Message{client_id: id}), do: Map.put(doc, "client_id", id)

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

  defp authorize_delete(_channel, %Message{user_id: user_id}, user_id), do: :ok

  defp authorize_delete(%ChannelCache{} = channel, %Message{}, user_id) do
    case Access.for_channel(channel).can_moderate?(channel, user_id) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :message_delete_denied}
      {:error, _reason} = error -> error
    end
  end

  defp apply_delete(%Message{} = message, actor_id) do
    deleted_at = DateTime.utc_now() |> DateTime.truncate(:millisecond)

    with :ok <- enqueue_deleted(message, deleted_at) do
      write_delete(message, actor_id, deleted_at)
    end
  end

  defp enqueue_deleted(%Message{} = message, deleted_at) do
    entry = %{
      event: "message_deleted",
      topic: "channel:" <> message.channel_id,
      payload: Message.to_deleted_api(%{message | deleted_at: deleted_at}),
      apply: %{
        "op" => "delete_message",
        "id" => message.id,
        "channel_id" => message.channel_id,
        "deleted_at" => Message.iso8601_z(deleted_at)
      },
      message_id: message.id,
      channel_id: message.channel_id
    }

    enqueue_or_unavailable(
      [entry, DomainEvent.message_deleted(message, deleted_at)],
      message.channel_id
    )
  end

  defp enqueue_or_unavailable(entries, channel_id) do
    case Outbox.enqueue(entries) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("message_enqueue_failed", channel_id: channel_id, reason: Log.reason(reason))
        {:error, :messages_unavailable}
    end
  end

  defp write_delete(%Message{} = message, actor_id, deleted_at) do
    case repo().delete_message(message.id, message.channel_id, deleted_at) do
      {:ok, nil} ->
        {:error, :message_not_found}

      {:ok, doc} ->
        Logger.info("message_deleted",
          channel_id: message.channel_id,
          actor_id: actor_id,
          author_id: message.user_id,
          message_id: message.id
        )

        forget_mentions(message)
        forget_reactions(message)
        forget_attachments(message)
        {:ok, Message.from_doc(doc)}

      {:error, reason} ->
        Logger.warning("message_delete_deferred",
          channel_id: message.channel_id,
          message_id: message.id,
          reason: Log.reason(reason)
        )

        {:ok, %{message | content: "", attachments: [], deleted_at: deleted_at}}
    end
  end

  # A deleted message must not keep notifications that point at it.
  defp forget_mentions(%Message{} = message) do
    if Message.mentions?(message) do
      case repo().delete_mentions(message.id, []) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("mentions_delete_failed",
            message_id: message.id,
            reason: Log.reason(reason)
          )
      end
    end
  end

  defp forget_attachments(%Message{attachments: []}), do: :ok

  defp forget_attachments(%Message{} = message) do
    at = DateTime.utc_now() |> DateTime.truncate(:millisecond)

    case repo().orphan_message_attachments(message.id, at) do
      :ok ->
        AttachmentCleaner.trigger()

      {:error, reason} ->
        Logger.warning("attachments_orphan_failed",
          message_id: message.id,
          reason: Log.reason(reason)
        )
    end
  end

  defp forget_reactions(%Message{} = message) do
    case repo().delete_reactions(message.id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("reactions_delete_failed",
          message_id: message.id,
          reason: Log.reason(reason)
        )
    end
  end

  defp apply_edit(_channel, %Message{content: content} = message, content, _actor_id),
    do: {:ok, message, :unchanged}

  defp apply_edit(%ChannelCache{} = channel, %Message{} = message, new_content, actor_id) do
    added = CustomEmoji.added_tokens(new_content, message.content)

    with :ok <- check_word_filter(channel, new_content),
         :ok <- CustomEmoji.authorize(actor_id, added, channel.server_id),
         {:ok, mentions} <- resolve_mentions(channel, new_content, actor_id) do
      update_content(channel, message, new_content, mentions)
    end
  end

  defp update_content(%ChannelCache{} = channel, %Message{} = message, new_content, mentions) do
    edited_at = DateTime.utc_now() |> DateTime.truncate(:millisecond)
    mention_fields = Mentions.message_fields(mentions)

    with :ok <-
           enqueue_updated(channel, message, new_content, edited_at, mentions, mention_fields) do
      write_update(message, new_content, edited_at, mentions, mention_fields)
    end
  end

  defp enqueue_updated(
         %ChannelCache{} = channel,
         %Message{} = message,
         new_content,
         edited_at,
         mentions,
         mention_fields
       ) do
    edited = edited_message(message, new_content, edited_at, mentions)

    fields =
      Map.merge(mention_fields, %{
        "content" => new_content,
        "edited_at" => Message.iso8601_z(edited_at),
        "changed_at" => Message.iso8601_z(edited_at)
      })

    entry = %{
      event: "message_updated",
      topic: "channel:" <> message.channel_id,
      payload: Message.to_api(edited),
      apply: %{
        "op" => "update_message",
        "id" => message.id,
        "channel_id" => message.channel_id,
        "fields" => fields
      },
      message_id: message.id,
      channel_id: message.channel_id
    }

    enqueue_or_unavailable(
      [entry | updated_entries(channel, edited, mentions)],
      message.channel_id
    )
  end

  defp updated_entries(%ChannelCache{server_id: nil}, _edited, _mentions), do: []

  defp updated_entries(%ChannelCache{} = channel, %Message{} = edited, %Mentions{} = mentions),
    do: [DomainEvent.message_updated(edited, mentions.recipient_ids, channel.name)]

  defp edited_message(%Message{} = message, new_content, edited_at, mentions) do
    %{
      message
      | content: new_content,
        edited_at: edited_at,
        mentions: mentions.user_ids,
        mention_roles: mentions.role_ids,
        mention_everyone: mentions.everyone
    }
  end

  defp write_update(%Message{} = message, new_content, edited_at, mentions, mention_fields) do
    case repo().update_message(
           message.id,
           message.channel_id,
           message.user_id,
           new_content,
           edited_at,
           mention_fields
         ) do
      {:ok, nil} ->
        {:error, :message_not_found}

      {:ok, doc} ->
        Logger.info("message_edited",
          channel_id: message.channel_id,
          user_id: message.user_id,
          message_id: message.id
        )

        edited = Message.from_doc(doc)
        sync_mentions(message, edited, mentions.recipient_ids)
        {:ok, edited, :updated}

      {:error, reason} ->
        Logger.warning("message_update_deferred",
          channel_id: message.channel_id,
          message_id: message.id,
          reason: Log.reason(reason)
        )

        {:ok, edited_message(message, new_content, edited_at, mentions), :updated}
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

  defp take_side(docs, half) do
    {page, rest} = Enum.split(docs, half)
    {Enum.map(page, &Message.from_doc/1), rest != []}
  end

  defp clamp_limit(n) when is_integer(n) and n > 0 and n <= @max_page_limit, do: n
  defp clamp_limit(_other), do: @default_page_limit
end
