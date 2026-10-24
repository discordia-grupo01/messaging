defmodule Messaging.Chat.Search do
  alias Messaging.Chat.{Conversation, Message, Replica}

  @max_text_length 100
  @default_limit 25
  @max_limit 50
  @count_cap 1_000

  @enforce_keys [:server_id, :user_id]
  defstruct [
    :server_id,
    :user_id,
    :text,
    :author_id,
    :channel_id,
    :before,
    limit: @default_limit
  ]

  @type t :: %__MODULE__{
          server_id: String.t(),
          user_id: String.t(),
          text: String.t() | nil,
          author_id: String.t() | nil,
          channel_id: String.t() | nil,
          before: String.t() | nil,
          limit: pos_integer()
        }

  @type total :: %{count: non_neg_integer(), capped: boolean()}

  @type page :: %{
          messages: [Message.t()],
          next_cursor: String.t() | nil,
          total: total() | nil
        }

  @type params :: %{
          required(:server_id) => String.t(),
          required(:user_id) => String.t(),
          optional(:text) => term(),
          optional(:author_id) => term(),
          optional(:channel_id) => term(),
          optional(:before) => term(),
          optional(:limit) => term()
        }

  def max_text_length, do: @max_text_length
  def max_limit, do: @max_limit
  def count_cap, do: @count_cap

  @doc """
  Runs a search. `total` is counted only on the first page (without `before`)
  and stops at #{@count_cap}: past that, `capped` is true.
  """
  @spec run(params()) :: {:ok, page()} | {:error, term()}
  def run(params) do
    with {:ok, search} <- new(params),
         {:ok, member} <- fetch_member(search),
         {:ok, channel_ids} <- searchable_channels(search, member),
         {:ok, before} <- resolve_cursor(search) do
      page(search, channel_ids, before)
    end
  end

  defp new(params) do
    with {:ok, text} <- fetch_text(Map.get(params, :text)),
         {:ok, author_id} <- fetch_author(Map.get(params, :author_id)),
         :ok <- require_criteria(text, author_id) do
      {:ok,
       %__MODULE__{
         server_id: Map.fetch!(params, :server_id),
         user_id: Map.fetch!(params, :user_id),
         text: text,
         author_id: author_id,
         channel_id: optional_id(Map.get(params, :channel_id)),
         before: optional_id(Map.get(params, :before)),
         limit: clamp_limit(Map.get(params, :limit))
       }}
    end
  end

  defp fetch_text(nil), do: {:ok, nil}

  defp fetch_text(text) when is_binary(text) do
    case String.trim(text) do
      "" -> {:ok, nil}
      trimmed -> check_length(trimmed)
    end
  end

  defp fetch_text(_other), do: {:error, :invalid_search_query}

  defp check_length(text) do
    if String.length(text) > @max_text_length,
      do: {:error, :invalid_search_query},
      else: {:ok, text}
  end

  defp fetch_author(nil), do: {:ok, nil}
  defp fetch_author(""), do: {:ok, nil}

  defp fetch_author(author_id) do
    if Conversation.valid_user_id?(author_id),
      do: {:ok, author_id},
      else: {:error, :invalid_search_query}
  end

  defp require_criteria(nil, nil), do: {:error, :invalid_search_query}
  defp require_criteria(_text, _author_id), do: :ok

  defp optional_id(id) when is_binary(id) and id != "", do: id
  defp optional_id(_other), do: nil

  defp clamp_limit(n) when is_integer(n) and n > 0 and n <= @max_limit, do: n
  defp clamp_limit(_other), do: @default_limit

  defp fetch_member(%__MODULE__{server_id: server_id, user_id: user_id}) do
    case repo().get_member(server_id, user_id) do
      nil -> {:error, :not_server_member}
      {:error, _reason} = error -> error
      member -> {:ok, member}
    end
  end

  defp searchable_channels(%__MODULE__{} = search, member) do
    role_ids = Map.get(member, "role_ids", [])

    with {:ok, text_ids} <- repo().list_text_channel_ids(search.server_id),
         {:ok, ids} <- scope(text_ids, search.channel_id),
         {:ok, visible_ids} <-
           Replica.viewable_channel_ids(search.server_id, search.user_id, role_ids, ids) do
      require_visible(visible_ids, search.channel_id)
    end
  end

  defp scope(text_ids, nil), do: {:ok, text_ids}

  defp scope(text_ids, channel_id) do
    if channel_id in text_ids,
      do: {:ok, [channel_id]},
      else: {:error, :channel_not_found}
  end

  defp require_visible([], channel_id) when is_binary(channel_id), do: {:error, :forbidden}
  defp require_visible(visible_ids, _channel_id), do: {:ok, visible_ids}

  defp resolve_cursor(%__MODULE__{before: nil}), do: {:ok, nil}

  defp resolve_cursor(%__MODULE__{before: id, server_id: server_id}) do
    case repo().get_message(id) do
      %{"server_id" => ^server_id, "inserted_at" => %DateTime{} = at} -> {:ok, {at, id}}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_cursor}
    end
  end

  defp page(%__MODULE__{} = search, channel_ids, before) do
    with {:ok, docs} <- find(search, channel_ids, before),
         {:ok, total} <- count(search, channel_ids) do
      {:ok, build_page(docs, search.limit, total)}
    end
  end

  defp find(_search, [], _before), do: {:ok, []}

  defp find(%__MODULE__{} = search, channel_ids, before) do
    opts = [
      text: search.text,
      author_id: search.author_id,
      before: before,
      limit: search.limit + 1
    ]

    repo().search_messages(channel_ids, opts)
  end

  defp count(%__MODULE__{before: before}, _channel_ids) when is_binary(before), do: {:ok, nil}
  defp count(%__MODULE__{}, []), do: {:ok, %{count: 0, capped: false}}

  defp count(%__MODULE__{} = search, channel_ids) do
    opts = [text: search.text, author_id: search.author_id]

    with {:ok, n} <- repo().count_search_matches(channel_ids, opts, @count_cap + 1) do
      {:ok, %{count: min(n, @count_cap), capped: n > @count_cap}}
    end
  end

  defp build_page(docs, limit, total) do
    {page, rest} = Enum.split(docs, limit)
    messages = Enum.map(page, &Message.from_doc/1)
    next_cursor = if rest == [], do: nil, else: List.last(messages).id
    %{messages: messages, next_cursor: next_cursor, total: total}
  end

  defp repo, do: Application.get_env(:messaging, :chat_repo, Messaging.Chat.Repo.Mongo)
end
