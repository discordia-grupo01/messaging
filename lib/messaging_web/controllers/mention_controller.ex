defmodule MessagingWeb.MentionController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Messaging.Chat
  alias Messaging.Chat.UserMention
  alias MessagingWeb.ApiError
  alias MessagingWeb.Schemas

  tags ["mentions"]

  operation :index,
    summary: "Mis menciones sin leer",
    description:
      "Las notificaciones destacadas (historia #46) que todavía no leíste, la más reciente " <>
        "primero, cada una con su mensaje. Las mismas que llegan en vivo como evento `mention` " <>
        "en `user:<tu id>`; acá están para quien estaba desconectado. Se marcan como leídas " <>
        "por canal con `POST /v1/channels/{channel_id}/mentions/read`.",
    parameters: [
      limit: [
        in: :query,
        type: :integer,
        required: false,
        description: "Cantidad máxima (default 50, máx 100)"
      ]
    ],
    responses: [
      ok: {"Menciones sin leer", "application/json", Schemas.MentionList},
      unauthorized:
        {"Falta o es inválido el Authorization: Bearer <jwt>", "application/json",
         Schemas.ErrorResponse}
    ]

  def index(conn, params) do
    limit = params |> Map.get("limit") |> parse_limit()

    case Chat.list_mentions(conn.assigns.user_id, limit: limit) do
      {:ok, mentions} ->
        json(conn, %{"mentions" => Enum.map(mentions, &UserMention.to_api/1)})

      {:error, reason} ->
        respond_error(conn, reason)
    end
  end

  operation :read,
    summary: "Marcar como leídas mis menciones de un canal",
    description:
      "Marca como leídas todas tus menciones en ese canal (por ejemplo, al abrirlo). " <>
        "Las que lleguen después siguen sin leer. Es idempotente.",
    parameters: [
      channel_id: [in: :path, type: :string, required: true, description: "UUID del canal"]
    ],
    responses: [
      no_content: "Menciones del canal marcadas como leídas",
      unauthorized:
        {"Falta o es inválido el Authorization: Bearer <jwt>", "application/json",
         Schemas.ErrorResponse},
      not_found: {"El canal no existe", "application/json", Schemas.ErrorResponse}
    ]

  def read(conn, %{"channel_id" => channel_id}) do
    case Chat.mark_mentions_read(channel_id, conn.assigns.user_id) do
      :ok -> send_resp(conn, 204, "")
      {:error, reason} -> respond_error(conn, reason)
    end
  end

  defp respond_error(conn, reason)
       when reason in [
              :channel_not_found,
              :channel_not_text,
              :server_suspended,
              :suspension_unavailable
            ],
       do: conn |> put_status(ApiError.http_status(reason)) |> json(ApiError.payload(reason))

  defp respond_error(conn, _reason),
    do: conn |> put_status(503) |> json(ApiError.payload(:mentions_unavailable))

  defp parse_limit(nil), do: nil

  defp parse_limit(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, _rest} -> n
      :error -> nil
    end
  end
end
