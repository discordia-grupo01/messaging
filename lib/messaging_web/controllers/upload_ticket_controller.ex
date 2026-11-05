defmodule MessagingWeb.UploadTicketController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Messaging.Auth.UploadTicket
  alias MessagingWeb.ApiError
  alias MessagingWeb.Schemas

  tags ["attachments"]

  operation :create,
    summary: "Emite un ticket de un solo uso para subir un archivo",
    description:
      "Para un cliente que no tiene el JWT en el navegador: lo pide su backend con el Bearer " <>
        "normal, y el navegador sube el archivo a `POST /v1/attachments/direct` con el header " <>
        "`X-Upload-Ticket`. Cada ticket sirve para un solo pedido, aunque ese pedido falle.",
    responses: [
      created: {"Ticket emitido", "application/json", Schemas.UploadTicket},
      unauthorized:
        {"Falta o es inválido el Authorization: Bearer <jwt>", "application/json",
         Schemas.ErrorResponse},
      service_unavailable:
        {"No se pudo guardar el ticket", "application/json", Schemas.ErrorResponse}
    ]

  def create(conn, _params) do
    case UploadTicket.issue(conn.assigns.user_id) do
      {:ok, ticket} ->
        conn
        |> put_status(201)
        |> json(%{"ticket" => ticket, "expires_in" => UploadTicket.ttl_seconds()})

      {:error, _reason} ->
        conn
        |> put_status(ApiError.http_status(:ticket_unavailable))
        |> json(ApiError.payload(:ticket_unavailable))
    end
  end
end
