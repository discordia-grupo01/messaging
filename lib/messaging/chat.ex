defmodule Messaging.Chat do
  alias Messaging.Chat.{ChannelCache, Message}
  alias Messaging.UUID

  require Logger

  @max_message_length 2_000
  @default_page_limit 50
  @max_page_limit 100

  def max_message_length, do: @max_message_length

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

  @spec list_messages(String.t(), keyword()) ::
          {:ok, [Message.t()], String.t() | nil} | {:error, atom()}
  def list_messages(channel_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit) |> clamp_limit()

    with {:ok, before_dt} <- resolve_cursor(Keyword.get(opts, :before)),
         {:ok, docs} <- repo().list_messages(channel_id, before: before_dt, limit: limit) do
      messages = Enum.map(docs, &Message.from_doc/1)
      {:ok, messages, next_cursor(messages, limit)}
    end
  end

  @spec messages_since(String.t(), DateTime.t()) :: {:ok, [Message.t()]} | {:error, atom()}
  def messages_since(channel_id, %DateTime{} = since) do
    case repo().list_messages(channel_id, before: nil, limit: @max_page_limit) do
      {:ok, docs} ->
        messages =
          docs
          |> Enum.map(&Message.from_doc/1)
          |> Enum.filter(&(DateTime.compare(&1.inserted_at, since) == :gt))
          |> Enum.reverse()

        {:ok, messages}

      {:error, _reason} = error ->
        error
    end
  end

  @spec channel_exists?(String.t()) :: {:ok, ChannelCache.t()} | {:error, atom()}
  def channel_exists?(channel_id), do: fetch_text_channel(channel_id)

  @spec can_send_messages?(ChannelCache.t(), String.t(), String.t()) ::
          {:ok, boolean()} | {:error, term()}
  def can_send_messages?(%ChannelCache{} = channel, user_id, raw_jwt),
    do: check_permission(channel, user_id, raw_jwt)

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
      id: UUID.generate(),
      channel_id: channel.channel_id,
      server_id: channel.server_id,
      user_id: user_id,
      content: content,
      inserted_at: DateTime.utc_now()
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

  defp resolve_cursor(nil), do: {:ok, nil}

  defp resolve_cursor(message_id) do
    case repo().get_message(message_id) do
      nil -> {:error, :invalid_cursor}
      {:error, _reason} -> {:error, :invalid_cursor}
      doc -> {:ok, Message.from_doc(doc).inserted_at}
    end
  end

  defp next_cursor(messages, limit) do
    if length(messages) == limit do
      %Message{id: id} = List.last(messages)
      id
    else
      nil
    end
  end

  defp clamp_limit(n) when is_integer(n) and n > 0 and n <= @max_page_limit, do: n
  defp clamp_limit(_other), do: @default_page_limit
end
