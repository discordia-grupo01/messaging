defmodule MessagingWeb.Plugs.PathParamLength do
  import Plug.Conn

  alias MessagingWeb.ApiError

  @max_length 64

  def init(opts), do: opts

  def call(conn, _opts) do
    if Enum.all?(conn.path_params, fn {_name, value} ->
         length(String.codepoints(value)) <= @max_length
       end) do
      conn
    else
      conn
      |> put_status(ApiError.http_status(:invalid_payload))
      |> Phoenix.Controller.json(ApiError.payload(:invalid_payload))
      |> halt()
    end
  end
end
