defmodule Messaging.Auth.UploadTicket do
  @moduledoc """
  Lets a browser upload straight to the gateway without ever holding the JWT. It
  is redeemed when the request arrives, before the file is read: the gateway has
  to stream that route instead of buffering it, or a slow upload would outlive it.
  """
  alias Messaging.Auth.Ticket

  @ttl_seconds 60

  def ttl_seconds, do: @ttl_seconds

  @spec issue(String.t()) :: {:ok, String.t()} | {:error, term()}
  def issue(user_id), do: Ticket.issue(:upload, user_id, @ttl_seconds)

  @spec redeem(term()) :: {:ok, Ticket.redeemed()} | {:error, :invalid_ticket}
  def redeem(ticket), do: Ticket.redeem(:upload, ticket)
end
