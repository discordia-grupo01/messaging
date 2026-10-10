defmodule MessagingWeb.SocketTicketController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Messaging.Auth.SocketTicket
  alias MessagingWeb.ApiError
  alias MessagingWeb.Schemas

  tags ["auth"]

  operation :create,
    summary: "Emite un ticket de un solo uso para conectar el WebSocket",
    description:
      "El navegador no puede mandar el header Authorization al abrir un WebSocket, y poner el JWT en la URL lo deja en logs. En su lugar, el cliente pide acá un ticket (autenticado con el Bearer normal) y conecta con `?ticket=<ticket>`.",
    responses: [
      created: {"Ticket emitido", "application/json", Schemas.SocketTicket},
      unauthorized:
        {"Falta o es inválido el Authorization: Bearer <jwt>", "application/json",
         Schemas.ErrorResponse},
      service_unavailable:
        {"No se pudo guardar el ticket", "application/json", Schemas.ErrorResponse}
    ]

  def create(conn, _params) do
    case SocketTicket.issue(conn.assigns.user_id) do
      {:ok, ticket} ->
        conn
        |> put_status(201)
        |> json(%{"ticket" => ticket, "expires_in" => SocketTicket.ttl_seconds()})

      {:error, _reason} ->
        conn
        |> put_status(ApiError.http_status(:ticket_unavailable))
        |> json(ApiError.payload(:ticket_unavailable))
    end
  end
end
