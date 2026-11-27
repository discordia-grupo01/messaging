defmodule MessagingWeb.ConversationController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Messaging.Chat
  alias Messaging.Chat.Conversation
  alias MessagingWeb.ApiError
  alias MessagingWeb.LimitParam
  alias MessagingWeb.Schemas

  tags ["conversations"]

  operation :index,
    summary: "Mis conversaciones directas",
    description:
      "Solo aparecen las conversaciones que ya tienen al menos un mensaje, la más reciente " <>
        "primero. `unread` es `true` si el último mensaje es del otro participante y todavía " <>
        "no lo marcaste como leído. `last_message` es `null` si ese mensaje fue eliminado. " <>
        "Para ver el historial de una conversación se usa " <>
        "`GET /v1/channels/{id}/messages` con el `id` de la conversación.",
    parameters: [
      limit: [
        in: :query,
        type: :integer,
        required: false,
        description: "Cantidad máxima (default 50, máx 100)"
      ]
    ],
    responses: [
      ok: {"Conversaciones del usuario", "application/json", Schemas.ConversationList},
      bad_request:
        {"`limit` no es un número entero (`INVALID_BODY`)", "application/json",
         Schemas.ErrorResponse},
      unauthorized:
        {"Falta o es inválido el Authorization: Bearer <jwt>", "application/json",
         Schemas.ErrorResponse}
    ]

  def index(conn, params) do
    user_id = conn.assigns.user_id

    with {:ok, limit} <- LimitParam.parse(Map.get(params, "limit")),
         {:ok, conversations} <- Chat.list_conversations(user_id, limit: limit) do
      json(conn, %{
        "conversations" => Enum.map(conversations, &Conversation.to_api(&1, user_id))
      })
    else
      {:error, reason} ->
        conn |> put_status(ApiError.http_status(reason)) |> json(ApiError.payload(reason))
    end
  end

  operation :read,
    summary: "Marcar una conversación como leída",
    description:
      "Marca como leído todo hasta el último mensaje que hoy tiene la conversación. Un " <>
        "mensaje que llegue después sigue sin leer. Si no existe o no sos participante, 404.",
    parameters: [
      id: [
        in: :path,
        schema: %OpenApiSpex.Schema{type: :string, maxLength: 64},
        required: true,
        description: "Id de la conversación"
      ]
    ],
    responses: [
      no_content: "Conversación marcada como leída",
      bad_request:
        {"Un parámetro de la ruta supera los 64 caracteres (`INVALID_BODY`)", "application/json",
         Schemas.ErrorResponse},
      unauthorized:
        {"Falta o es inválido el Authorization: Bearer <jwt>", "application/json",
         Schemas.ErrorResponse},
      not_found:
        {"La conversación no existe o el usuario no participa", "application/json",
         Schemas.ErrorResponse}
    ]

  def read(conn, %{"id" => conversation_id}) do
    case Chat.mark_read(conversation_id, conn.assigns.user_id) do
      :ok ->
        send_resp(conn, 204, "")

      {:error, reason} ->
        conn |> put_status(ApiError.http_status(reason)) |> json(ApiError.payload(reason))
    end
  end
end
