defmodule Messaging.Auth.SocketTicket do
  alias Messaging.Log

  require Logger

  @ttl_seconds 30

  @type redeemed :: %{user_id: String.t()}

  def ttl_seconds, do: @ttl_seconds

  defp store, do: Application.get_env(:messaging, :ticket_store, Messaging.Auth.TicketStore.Mongo)

  @spec issue(String.t()) :: {:ok, String.t()} | {:error, term()}
  def issue(user_id) do
    ticket = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    doc = %{
      "_id" => hash(ticket),
      "user_id" => user_id,
      "expires_at" => DateTime.add(DateTime.utc_now(), @ttl_seconds, :second)
    }

    case store().put(doc) do
      :ok ->
        Logger.info("socket_ticket_issued", user_id: user_id)
        {:ok, ticket}

      {:error, reason} = error ->
        Logger.error("socket_ticket_issue_failed", user_id: user_id, reason: Log.reason(reason))

        error
    end
  end

  @spec redeem(term()) :: {:ok, redeemed()} | {:error, :invalid_ticket}
  def redeem(ticket) when is_binary(ticket) do
    case store().take(hash(ticket)) do
      {:ok, %{"user_id" => user_id, "expires_at" => expires_at}} ->
        if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
          {:ok, %{user_id: user_id}}
        else
          Logger.warning("socket_ticket_rejected", cause: "expired", user_id: user_id)
          {:error, :invalid_ticket}
        end

      {:ok, nil} ->
        Logger.warning("socket_ticket_rejected", cause: "unknown_or_already_used")
        {:error, :invalid_ticket}

      {:error, reason} ->
        Logger.error("socket_ticket_rejected", cause: "store_error", reason: Log.reason(reason))
        {:error, :invalid_ticket}
    end
  end

  def redeem(_other), do: {:error, :invalid_ticket}

  defp hash(ticket), do: :sha256 |> :crypto.hash(ticket) |> Base.encode16(case: :lower)
end
