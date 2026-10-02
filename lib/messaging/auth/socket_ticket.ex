defmodule Messaging.Auth.SocketTicket do
  require Logger

  @ttl_seconds 30

  @type redeemed :: %{user_id: String.t(), raw_jwt: String.t()}

  def ttl_seconds, do: @ttl_seconds

  defp store, do: Application.get_env(:messaging, :ticket_store, Messaging.Auth.TicketStore.Mongo)

  @spec issue(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def issue(user_id, raw_jwt) do
    ticket = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    doc = %{
      "_id" => hash(ticket),
      "user_id" => user_id,
      "raw_jwt" => raw_jwt,
      "expires_at" => DateTime.add(DateTime.utc_now(), @ttl_seconds, :second)
    }

    case store().put(doc) do
      :ok ->
        Logger.info("messaging: socket_ticket_issued user_id=#{user_id}")
        {:ok, ticket}

      {:error, reason} = error ->
        Logger.warning(
          "messaging: socket_ticket_issue_failed user_id=#{user_id} reason=#{inspect(reason)}"
        )

        error
    end
  end

  @spec redeem(term()) :: {:ok, redeemed()} | {:error, :invalid_ticket}
  def redeem(ticket) when is_binary(ticket) do
    case store().take(hash(ticket)) do
      {:ok, %{"user_id" => user_id, "raw_jwt" => raw_jwt, "expires_at" => expires_at}} ->
        if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
          {:ok, %{user_id: user_id, raw_jwt: raw_jwt}}
        else
          Logger.warning("messaging: socket_ticket_rejected reason=expired user_id=#{user_id}")
          {:error, :invalid_ticket}
        end

      {:ok, nil} ->
        Logger.warning("messaging: socket_ticket_rejected reason=unknown_or_already_used")
        {:error, :invalid_ticket}

      {:error, reason} ->
        Logger.warning("messaging: socket_ticket_rejected reason=#{inspect(reason)}")
        {:error, :invalid_ticket}
    end
  end

  def redeem(_other), do: {:error, :invalid_ticket}

  defp hash(ticket), do: :sha256 |> :crypto.hash(ticket) |> Base.encode16(case: :lower)
end
