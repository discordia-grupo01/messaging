defmodule Messaging.Auth.Ticket do
  @moduledoc """
  Single-use tickets stored hashed. The kind is part of the hash, so a ticket of
  one kind is never found (nor spent) when redeemed as another.
  """
  alias Messaging.Log

  require Logger

  @type kind :: :socket | :upload
  @type redeemed :: %{user_id: String.t()}

  defp store, do: Application.get_env(:messaging, :ticket_store, Messaging.Auth.TicketStore.Mongo)

  @spec issue(kind(), String.t(), pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def issue(kind, user_id, ttl_seconds) do
    ticket = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    doc = %{
      "_id" => hash(kind, ticket),
      "user_id" => user_id,
      "expires_at" => DateTime.add(DateTime.utc_now(), ttl_seconds, :second)
    }

    case store().put(doc) do
      :ok ->
        Logger.info("#{kind}_ticket_issued", user_id: user_id)
        {:ok, ticket}

      {:error, reason} = error ->
        Logger.error("#{kind}_ticket_issue_failed", user_id: user_id, reason: Log.reason(reason))

        error
    end
  end

  @spec redeem(kind(), term()) :: {:ok, redeemed()} | {:error, :invalid_ticket}
  def redeem(kind, ticket) when is_binary(ticket) do
    case store().take(hash(kind, ticket)) do
      {:ok, %{"user_id" => user_id, "expires_at" => expires_at}} ->
        if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
          {:ok, %{user_id: user_id}}
        else
          Logger.warning("#{kind}_ticket_rejected", cause: "expired", user_id: user_id)
          {:error, :invalid_ticket}
        end

      {:ok, nil} ->
        Logger.warning("#{kind}_ticket_rejected", cause: "unknown_or_already_used")
        {:error, :invalid_ticket}

      {:error, reason} ->
        Logger.error("#{kind}_ticket_rejected", cause: "store_error", reason: Log.reason(reason))
        {:error, :invalid_ticket}
    end
  end

  def redeem(_kind, _other), do: {:error, :invalid_ticket}

  defp hash(kind, ticket),
    do: :sha256 |> :crypto.hash("#{kind}:#{ticket}") |> Base.encode16(case: :lower)
end
