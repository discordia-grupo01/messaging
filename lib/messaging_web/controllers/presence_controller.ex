defmodule MessagingWeb.PresenceController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias Messaging.Chat.Conversation
  alias Messaging.Log
  alias Messaging.Presence
  alias MessagingWeb.ApiError
  alias MessagingWeb.Schemas

  tags ["presence"]

  operation :index,
    summary: "Estado de actividad de varios usuarios",
    description:
      "La foto inicial para la lista de mensajes directos o un perfil público; los cambios " <>
        "siguientes llegan por el socket (`presence_updated`). Para la lista de miembros de " <>
        "un servidor conviene unirse a `presence:<server_id>`, cuyo `join` ya trae la foto. " <>
        "`invisible` se ve como `offline`, igual que cualquiera con un bloqueo con quien " <>
        "pregunta, en cualquier dirección.",
    parameters: [
      user_ids: [
        in: :query,
        type: :string,
        required: true,
        description: "Ids separados por coma, hasta #{Presence.max_snapshot_users()}"
      ]
    ],
    responses: [
      ok: {"Estado de cada usuario pedido", "application/json", Schemas.PresenceList},
      bad_request:
        {"Faltan los ids, son más de #{Presence.max_snapshot_users()} o alguno no es válido",
         "application/json", Schemas.ErrorResponse},
      unauthorized:
        {"Falta o es inválido el Authorization: Bearer <jwt>", "application/json",
         Schemas.ErrorResponse},
      service_unavailable:
        {"No se pudo leer el estado de actividad", "application/json", Schemas.ErrorResponse}
    ]

  def index(conn, params) do
    with {:ok, user_ids} <- parse_ids(Map.get(params, "user_ids")),
         {:ok, presences} <- Presence.snapshot(conn.assigns.user_id, user_ids) do
      json(conn, %{"presences" => presences})
    else
      {:error, :invalid_payload} ->
        error(conn, :invalid_payload)

      {:error, reason} ->
        Logger.error("presence_snapshot_failed", reason: Log.reason(reason))
        error(conn, :presence_unavailable)
    end
  end

  defp parse_ids(raw) when is_binary(raw) do
    ids = raw |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> Enum.uniq()

    if ids != [] and length(ids) <= Presence.max_snapshot_users() and
         Enum.all?(ids, &Conversation.valid_user_id?/1),
       do: {:ok, ids},
       else: {:error, :invalid_payload}
  end

  defp parse_ids(_missing), do: {:error, :invalid_payload}

  defp error(conn, reason),
    do: conn |> put_status(ApiError.http_status(reason)) |> json(ApiError.payload(reason))
end
