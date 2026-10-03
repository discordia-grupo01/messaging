defmodule Messaging.Chat do
  alias Messaging.Chat.{ChannelCache, Message}
  alias Messaging.UUID

  require Logger

  @max_message_length 2_000
  @default_page_limit 50
  @max_page_limit 100

  def max_message_length, do: @max_message_length
  def max_page_limit, do: @max_page_limit

  defp repo, do: Application.get_env(:messaging, :chat_repo, Messaging.Chat.Repo.Mongo)

  defp permissions_client,
    do:
      Application.get_env(:messaging, :permissions_client, Messaging.Chat.PermissionsClient.Http)

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
         {:ok, true} <- check_permission(channel, user_id, raw_jwt) do
      persist_message(channel, user_id, trimmed)
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
    with {:ok, channel} <- fetch_text_channel(channel_id),
         {:ok, true} <- check_permission(channel, user_id, raw_jwt),
         {:ok, message} <- fetch_message(channel_id, message_id),
         :ok <- require_author(message, user_id),
         {:ok, trimmed} <- validate_content(content) do
      apply_edit(message, trimmed)
    else
      {:ok, false} -> {:error, :forbidden}
      {:error, _reason} = error -> error
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

  @spec channel_exists?(String.t()) :: {:ok, ChannelCache.t()} | {:error, atom()}
  def channel_exists?(channel_id), do: fetch_text_channel(channel_id)

  @spec can_view_channel?(ChannelCache.t(), String.t(), String.t()) ::
          {:ok, boolean()} | {:error, term()}
  def can_view_channel?(%ChannelCache{server_id: server_id}, user_id, raw_jwt),
    do: permissions_client().can_view_channel?(server_id, user_id, raw_jwt)

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

  @spec mongo_ready?() :: boolean()
  def mongo_ready?, do: repo().ping() == :ok

  defp fetch_text_channel(channel_id) do
    case repo().get_channel(channel_id) do
      nil -> {:error, :channel_not_found}
      {:error, _reason} = error -> error
      doc -> validate_kind(ChannelCache.from_doc(doc))
    end
  end

  defp validate_kind(%ChannelCache{} = channel) do
    if ChannelCache.text_channel?(channel), do: {:ok, channel}, else: {:error, :channel_not_text}
  end

  defp validate_content(content) do
    trimmed = content |> to_string() |> String.trim()

    cond do
      trimmed == "" -> {:error, :empty_content}
      String.length(trimmed) > @max_message_length -> {:error, :message_too_long}
      true -> {:ok, trimmed}
    end
  end

  defp check_permission(%ChannelCache{server_id: server_id}, user_id, raw_jwt) do
    permissions_client().can_send_messages?(server_id, user_id, raw_jwt)
  end

  defp persist_message(%ChannelCache{} = channel, user_id, content) do
    message = %Message{
      id: UUID.generate_v7(),
      channel_id: channel.channel_id,
      server_id: channel.server_id,
      user_id: user_id,
      content: content,
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:millisecond)
    }

    doc = %{
      "_id" => message.id,
      "channel_id" => message.channel_id,
      "server_id" => message.server_id,
      "user_id" => message.user_id,
      "content" => message.content,
      "inserted_at" => message.inserted_at
    }

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

  defp exclusive_cursors(nil, _after_id), do: :ok
  defp exclusive_cursors(_before_id, nil), do: :ok
  defp exclusive_cursors(_before_id, _after_id), do: {:error, :invalid_cursor}

  defp fetch_message(channel_id, message_id) when is_binary(message_id) do
    case repo().get_message(message_id) do
      %{"channel_id" => ^channel_id} = doc -> {:ok, Message.from_doc(doc)}
      _other -> {:error, :message_not_found}
    end
  end

  defp fetch_message(_channel_id, _message_id), do: {:error, :message_not_found}

  defp require_author(%Message{user_id: user_id}, user_id), do: :ok
  defp require_author(%Message{}, _user_id), do: {:error, :not_message_author}

  defp apply_edit(%Message{content: content} = message, content), do: {:ok, message, :unchanged}

  defp apply_edit(%Message{} = message, new_content) do
    edited_at = DateTime.utc_now() |> DateTime.truncate(:millisecond)

    case repo().update_message(
           message.id,
           message.channel_id,
           message.user_id,
           new_content,
           edited_at
         ) do
      {:ok, nil} ->
        {:error, :message_not_found}

      {:ok, doc} ->
        Logger.info(
          "messaging: message_edited channel_id=#{message.channel_id} user_id=#{message.user_id} message_id=#{message.id}"
        )

        {:ok, Message.from_doc(doc), :updated}

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
