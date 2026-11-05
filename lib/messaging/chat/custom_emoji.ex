defmodule Messaging.Chat.CustomEmoji do
  @moduledoc """
  Custom server emojis, written in messages and reactions as `<:name:id>` or
  `<a:name:id>` (animated). servers owns them; `replica_emojis` is fed by its
  events and keeps the deleted ones, so old content can still show them.

  To use one, it must exist, not be deleted, and belong to a server the user is
  a member of. An animated one, one from another server or one used in a direct
  message also requires Premium.
  """

  require Logger

  alias Messaging.Chat.Repo
  alias Messaging.Log
  alias Messaging.Premium

  @max_ids 100

  @type token :: %{text: String.t(), animated: boolean(), name: String.t(), id: String.t()}

  def max_ids, do: @max_ids

  @spec token?(String.t()) :: boolean()
  def token?(text),
    do: text =~ ~r/\A<a?:[A-Za-z0-9_]{2,32}:[0-9a-f-]{36}>\z/ and tokens(text) != []

  @spec tokens(String.t()) :: [token()]
  def tokens(text) do
    ~r/<(a?):([A-Za-z0-9_]{2,32}):([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})>/
    |> Regex.scan(text)
    |> Enum.map(fn [full, animated, name, id] ->
      %{text: full, animated: animated == "a", name: name, id: id}
    end)
    |> Enum.uniq()
  end

  @doc "The tokens of `new_text` that `old_text` didn't have."
  @spec added_tokens(String.t(), String.t()) :: [token()]
  def added_tokens(new_text, old_text), do: tokens(new_text) -- tokens(old_text)

  @doc """
  Whether `user_id` can use `tokens` in `server_id` (`nil` in a direct message).
  """
  @spec authorize(String.t(), [token()], String.t() | nil) ::
          :ok | {:error, :custom_emoji_not_allowed | :custom_emojis_unavailable}
  def authorize(_user_id, [], _server_id), do: :ok

  def authorize(user_id, tokens, server_id) do
    with {:ok, emojis} <- fetch_active(tokens),
         :ok <- ensure_member(user_id, emojis),
         :ok <- ensure_premium(user_id, emojis, server_id) do
      :ok
    else
      {:error, :custom_emoji_not_allowed} = denied ->
        denied

      {:error, reason} ->
        Logger.error("custom_emoji_check_failed", reason: Log.reason(reason))
        {:error, :custom_emojis_unavailable}
    end
  end

  @doc "The emojis with those ids, deleted ones included, so clients can draw old content."
  @spec list([String.t()]) ::
          {:ok, [map()]} | {:error, :too_many_custom_emojis | :custom_emojis_unavailable}
  def list(ids) when length(ids) > @max_ids, do: {:error, :too_many_custom_emojis}

  def list(ids) do
    valid_ids = ids |> Enum.filter(&uuid?/1) |> Enum.uniq()

    case Repo.impl().get_custom_emojis(valid_ids) do
      {:ok, docs} ->
        {:ok, Enum.map(docs, &to_api/1)}

      {:error, reason} ->
        Logger.error("custom_emoji_list_failed", reason: Log.reason(reason))
        {:error, :custom_emojis_unavailable}
    end
  end

  defp uuid?(id),
    do: id =~ ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  defp fetch_active(tokens) do
    with {:ok, docs} <- Repo.impl().get_custom_emojis(Enum.map(tokens, & &1.id)) do
      by_id = Map.new(docs, &{&1["_id"], &1})

      if Enum.all?(tokens, &active_match?(&1, by_id[&1.id])),
        do: {:ok, docs},
        else: {:error, :custom_emoji_not_allowed}
    end
  end

  # The name and the animated mark must match too: <:name:id> on a GIF would
  # otherwise dodge the Premium check on the client's word.
  defp active_match?(_token, nil), do: false

  defp active_match?(token, doc) do
    doc["deleted"] != true and doc["name"] == token.name and doc["animated"] == token.animated
  end

  defp ensure_member(user_id, emojis) do
    emojis
    |> Enum.map(& &1["server_id"])
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn server_id, :ok ->
      case Repo.impl().get_member(server_id, user_id) do
        nil -> {:halt, {:error, :custom_emoji_not_allowed}}
        {:error, _reason} = error -> {:halt, error}
        _member -> {:cont, :ok}
      end
    end)
  end

  defp ensure_premium(user_id, emojis, server_id) do
    if Enum.any?(emojis, &(&1["animated"] or &1["server_id"] != server_id)) do
      case Premium.premium?(user_id) do
        {:ok, true} -> :ok
        {:ok, false} -> {:error, :custom_emoji_not_allowed}
        {:error, _reason} = error -> error
      end
    else
      :ok
    end
  end

  defp to_api(doc) do
    %{
      "id" => doc["_id"],
      "server_id" => doc["server_id"],
      "name" => doc["name"],
      "animated" => doc["animated"],
      "image_url" => doc["image_url"],
      "deleted" => doc["deleted"] == true
    }
  end
end
