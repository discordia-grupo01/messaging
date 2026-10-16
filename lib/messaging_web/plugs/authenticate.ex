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
      ensure_active(conn, user_id)
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

  defp ensure_active(conn, user_id) do
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
end
