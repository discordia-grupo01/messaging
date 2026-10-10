defmodule MessagingWeb.BlockController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Messaging.Chat.{Blocks, Message}
  alias MessagingWeb.ApiError
  alias MessagingWeb.Schemas

  tags ["blocks"]

  operation :index,
    summary: "Usuarios que bloqueé",
    description:
      "Solo ves a quién bloqueaste vos, la más reciente primero. Nunca se informa quién te " <>
        "bloqueó a vos.",
    parameters: [
      limit: [
        in: :query,
        type: :integer,
        required: false,
        description: "Cantidad máxima (default 50, máx 100)"
      ]
    ],
    responses: [
      ok: {"Usuarios bloqueados", "application/json", Schemas.BlockList},
      unauthorized:
        {"Falta o es inválido el Authorization: Bearer <jwt>", "application/json",
         Schemas.ErrorResponse}
    ]

  def index(conn, params) do
    limit = params |> Map.get("limit") |> parse_limit()

    case Blocks.list(conn.assigns.user_id, limit: limit) do
      {:ok, blocks} ->
        json(conn, %{
          "blocks" =>
            Enum.map(blocks, fn block ->
              %{"user_id" => block.user_id, "created_at" => Message.iso8601_z(block.created_at)}
            end)
        })

      {:error, reason} ->
        error(conn, reason)
    end
  end

  operation :create,
    summary: "Bloquear a un usuario",
    description:
      "Desde ese momento ninguno de los dos puede enviarle mensajes directos al otro, ni " <>
        "editar ni borrar los que ya envió: la persona bloqueada recibe `DM_NOT_DELIVERED` " <>
        "sin saber por qué, y quien bloqueó recibe `USER_BLOCKED`. El historial de la " <>
        "conversación se conserva para los dos. Es idempotente: bloquear a alguien ya " <>
        "bloqueado también responde 204. Se verifica que el usuario exista.",
    request_body: {"Usuario a bloquear", "application/json", Schemas.BlockRequest},
    responses: [
      no_content: "Usuario bloqueado",
      bad_request:
        {"Intentó bloquearse a sí mismo, o el cuerpo está mal formado", "application/json",
         Schemas.ErrorResponse},
      unauthorized:
        {"Falta o es inválido el Authorization: Bearer <jwt>", "application/json",
         Schemas.ErrorResponse},
      not_found: {"El usuario no existe", "application/json", Schemas.ErrorResponse},
      service_unavailable:
        {"No se pudo verificar al usuario", "application/json", Schemas.ErrorResponse}
    ]

  def create(conn, %{"user_id" => blocked_id}) when is_binary(blocked_id) do
    case Blocks.block(conn.assigns.user_id, blocked_id) do
      :ok -> send_resp(conn, 204, "")
      {:error, reason} -> error(conn, reason)
    end
  end

  def create(conn, _params), do: error(conn, :invalid_payload)

  operation :delete,
    summary: "Desbloquear a un usuario",
    description:
      "Esa persona vuelve a poder enviarle mensajes directos a quien la bloqueó (y al revés). " <>
        "Es idempotente: desbloquear a alguien que no estaba bloqueado también responde 204.",
    parameters: [
      user_id: [
        in: :path,
        type: :string,
        required: true,
        description: "Id del usuario a desbloquear"
      ]
    ],
    responses: [
      no_content: "Usuario desbloqueado",
      bad_request:
        {"Intentó desbloquearse a sí mismo", "application/json", Schemas.ErrorResponse},
      unauthorized:
        {"Falta o es inválido el Authorization: Bearer <jwt>", "application/json",
         Schemas.ErrorResponse},
      not_found: {"El id no es válido", "application/json", Schemas.ErrorResponse}
    ]

  def delete(conn, %{"user_id" => blocked_id}) do
    case Blocks.unblock(conn.assigns.user_id, blocked_id) do
      :ok -> send_resp(conn, 204, "")
      {:error, reason} -> error(conn, reason)
    end
  end

  defp error(conn, reason),
    do: conn |> put_status(ApiError.http_status(reason)) |> json(ApiError.payload(reason))

  defp parse_limit(nil), do: nil

  defp parse_limit(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, _rest} -> n
      :error -> nil
    end
  end
end
