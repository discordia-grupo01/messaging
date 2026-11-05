defmodule MessagingWeb.Plugs.Authenticate do
  import Plug.Conn

  alias Messaging.Auth.Token
  alias Messaging.Suspension
  alias MessagingWeb.ApiError

  def init(opts), do: opts

  def call(conn, _opts) do
    with [header] <- get_req_header(conn, "authorization"),
         "Bearer " <> token <- header,
         {:ok, user_id} <- Token.user_id(token) do
      assign_active(conn, user_id)
    else
      _other -> unauthorized(conn, "Token inválido o ausente.")
    end
  end

  def assign_active(conn, user_id) do
    case Suspension.ensure_active(user_id) do
      :ok ->
        assign(conn, :user_id, user_id)

      {:error, reason} ->
        conn
        |> put_status(ApiError.http_status(reason))
        |> Phoenix.Controller.json(ApiError.payload(reason))
        |> halt()
    end
  end

  def unauthorized(conn, message) do
    conn
    |> put_status(401)
    |> Phoenix.Controller.json(%{error: %{code: "UNAUTHORIZED", message: message, details: %{}}})
    |> halt()
  end
end
