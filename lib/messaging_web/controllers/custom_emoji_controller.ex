defmodule MessagingWeb.CustomEmojiController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Messaging.Chat
  alias MessagingWeb.ApiError
  alias MessagingWeb.Schemas

  tags ["custom-emojis"]

  operation :index,
    summary: "Datos de emojis personalizados",
    description:
      "Devuelve el nombre y la imagen de los emojis que aparecen en mensajes y reacciones " <>
        "como `<:nombre:id>` o `<a:nombre:id>`. Incluye los borrados, porque el contenido " <>
        "viejo los sigue mostrando, y no pide ser miembro del servidor: alguien con Premium " <>
        "puede usar en un canal el emoji de un servidor donde los demás no están. Los ids " <>
        "desconocidos no aparecen (por ejemplo, si se borró su servidor): ahí el cliente " <>
        "muestra `:nombre:`. Para elegir qué emoji usar está " <>
        "`GET /v1/servers/{serverId}/emojis`.",
    parameters: [
      ids: [
        in: :query,
        type: :string,
        required: true,
        description: "Ids separados por coma (hasta 100)"
      ]
    ],
    responses: [
      ok: {"Emojis encontrados", "application/json", Schemas.CustomEmojiList},
      bad_request: {"Más de 100 ids", "application/json", Schemas.ErrorResponse},
      unauthorized:
        {"Falta o es inválido el Authorization: Bearer <jwt>", "application/json",
         Schemas.ErrorResponse},
      service_unavailable:
        {"No se pudieron leer los emojis", "application/json", Schemas.ErrorResponse}
    ]

  def index(conn, params) do
    ids = params |> Map.get("ids", "") |> to_string() |> String.split(",", trim: true)

    case Chat.list_custom_emojis(ids) do
      {:ok, emojis} ->
        json(conn, %{"emojis" => emojis})

      {:error, reason} ->
        conn |> put_status(ApiError.http_status(reason)) |> json(ApiError.payload(reason))
    end
  end
end
