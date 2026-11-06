defmodule MessagingWeb.Plugs.AuthenticateUploadTicket do
  import Plug.Conn

  alias Messaging.Auth.UploadTicket
  alias MessagingWeb.Plugs.Authenticate

  def init(opts), do: opts

  def call(conn, _opts) do
    with [ticket] <- get_req_header(conn, "x-upload-ticket"),
         {:ok, %{user_id: user_id}} <- UploadTicket.redeem(ticket) do
      Authenticate.assign_active(conn, user_id)
    else
      _other -> Authenticate.unauthorized(conn, "Ticket de subida inválido o ausente.")
    end
  end
end
