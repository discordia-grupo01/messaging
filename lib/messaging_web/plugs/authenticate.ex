defmodule MessagingWeb.Plugs.Authenticate do
  import Plug.Conn

  alias Messaging.Auth.Token

  def init(opts), do: opts

  def call(conn, _opts) do
    with [header] <- get_req_header(conn, "authorization"),
         "Bearer " <> token <- header,
         {:ok, user_id} <- Token.user_id(token) do
      conn |> assign(:user_id, user_id) |> assign(:raw_jwt, token)
    else
      _other ->
        conn
        |> put_status(401)
        |> Phoenix.Controller.json(%{
          error: %{code: "UNAUTHORIZED", message: "Token inválido o ausente.", details: %{}}
        })
        |> halt()
    end
  end
end
