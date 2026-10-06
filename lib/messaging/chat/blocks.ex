defmodule Messaging.Chat.Blocks do
  alias Messaging.Chat.{Conversation, Repo, UsersClient}

  require Logger

  @default_limit 50
  @max_limit 100

  @type contact_error :: :user_blocked | :dm_not_delivered

  @spec block(String.t(), term(), String.t()) :: :ok | {:error, term()}
  def block(blocker_id, blocked_id, raw_jwt) do
    with :ok <- validate_target(blocker_id, blocked_id),
         :ok <- verify_user(blocked_id, raw_jwt) do
      doc = %{
        "_id" => id(blocker_id, blocked_id),
        "blocker_id" => blocker_id,
        "blocked_id" => blocked_id,
        "created_at" => DateTime.utc_now() |> DateTime.truncate(:millisecond)
      }

      log_failure(repo().put_block(doc), "block_failed")
    end
  end

  @spec unblock(String.t(), term()) :: :ok | {:error, term()}
  def unblock(blocker_id, blocked_id) do
    with :ok <- validate_target(blocker_id, blocked_id) do
      log_failure(repo().delete_block(id(blocker_id, blocked_id)), "unblock_failed")
    end
  end

  @spec list(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(blocker_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit) |> clamp_limit()

    with {:ok, docs} <- repo().list_blocks(blocker_id, limit) do
      {:ok, Enum.map(docs, &%{user_id: &1["blocked_id"], created_at: &1["created_at"]})}
    end
  end

  @spec check_contact(String.t(), String.t()) :: :ok | {:error, contact_error() | term()}
  def check_contact(sender_id, recipient_id) do
    mine = id(sender_id, recipient_id)
    theirs = id(recipient_id, sender_id)

    with {:ok, docs} <- repo().get_blocks([mine, theirs]) do
      ids = MapSet.new(docs, & &1["_id"])

      cond do
        MapSet.member?(ids, mine) -> {:error, :user_blocked}
        MapSet.member?(ids, theirs) -> {:error, :dm_not_delivered}
        true -> :ok
      end
    end
  end

  @spec blocked_among(String.t(), [String.t()]) :: {:ok, MapSet.t(String.t())} | {:error, term()}
  def blocked_among(_blocker_id, []), do: {:ok, MapSet.new()}

  def blocked_among(blocker_id, partner_ids) do
    with {:ok, docs} <- repo().get_blocks(Enum.map(partner_ids, &id(blocker_id, &1))) do
      {:ok, MapSet.new(docs, & &1["blocked_id"])}
    end
  end

  defp validate_target(user_id, user_id), do: {:error, :cannot_block_self}

  defp validate_target(_blocker_id, blocked_id) do
    if Conversation.valid_user_id?(blocked_id), do: :ok, else: {:error, :user_not_found}
  end

  defp verify_user(user_id, raw_jwt) do
    case UsersClient.verify(user_id, raw_jwt) do
      :ok -> :ok
      {:error, :not_found} -> {:error, :user_not_found}
      {:error, :unavailable} -> {:error, :users_unavailable}
    end
  end

  defp id(blocker_id, blocked_id), do: blocker_id <> ":" <> blocked_id

  defp log_failure(:ok, _event), do: :ok

  defp log_failure({:error, reason} = error, event) do
    Logger.warning("messaging: #{event} reason=#{inspect(reason)}")
    error
  end

  defp clamp_limit(n) when is_integer(n) and n > 0 and n <= @max_limit, do: n
  defp clamp_limit(_other), do: @default_limit

  defp repo, do: Repo.impl()
end
