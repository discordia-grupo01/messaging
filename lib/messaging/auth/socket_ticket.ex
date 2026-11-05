defmodule Messaging.Auth.SocketTicket do
  alias Messaging.Auth.Ticket

  @ttl_seconds 30

  def ttl_seconds, do: @ttl_seconds

  @spec issue(String.t()) :: {:ok, String.t()} | {:error, term()}
  def issue(user_id), do: Ticket.issue(:socket, user_id, @ttl_seconds)

  @spec redeem(term()) :: {:ok, Ticket.redeemed()} | {:error, :invalid_ticket}
  def redeem(ticket), do: Ticket.redeem(:socket, ticket)
end
