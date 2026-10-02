defmodule MessagingWeb.MessageController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Messaging.Chat
  alias Messaging.Chat.Message
  alias MessagingWeb.ApiError
  alias MessagingWeb.Schemas

  tags ["messages"]

  operation :index,
    summary: "Historial de mensajes de un canal",
    parameters: [
      channel_id: [in: :path, type: :string, required: true, description: "UUID del canal"],
      limit: [
        in: :query,
        type: :integer,
        required: false,
        description: "Tamaño de página (default 50, máx 100)"
      ],
      before: [
        in: :query,
        type: :string,
        required: false,
        description: "Id de mensaje devuelto como next_cursor en la página anterior"
      ]
    ],
    responses: [
      ok: {"Página de mensajes, más nuevos primero", "application/json", Schemas.MessageList},
      unauthorized:
        {"Falta o es inválido el Authorization: Bearer <jwt>", "application/json",
         Schemas.ErrorResponse},
      forbidden:
        {"El usuario no tiene SEND_MESSAGES en este canal", "application/json",
         Schemas.ErrorResponse},
      not_found: {"El canal no existe", "application/json", Schemas.ErrorResponse}
    ]

  def index(conn, %{"channel_id" => channel_id} = params) do
    user_id = conn.assigns.user_id
    raw_jwt = conn.assigns.raw_jwt
    limit = params |> Map.get("limit") |> parse_limit()
    before_id = Map.get(params, "before")

    with {:ok, channel} <- Chat.channel_exists?(channel_id),
         {:ok, true} <- Chat.can_send_messages?(channel, user_id, raw_jwt),
         {:ok, messages, next_cursor} <-
           Chat.list_messages(channel_id, limit: limit, before: before_id) do
      json(conn, %{
        "messages" => Enum.map(messages, &Message.to_api/1),
        "next_cursor" => next_cursor
      })
    else
      {:ok, false} ->
        conn |> put_status(403) |> json(ApiError.payload(:forbidden))

      {:error, reason} ->
        conn |> put_status(ApiError.http_status(reason)) |> json(ApiError.payload(reason))
    end
  end

  defp parse_limit(nil), do: nil

  defp parse_limit(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, _rest} -> n
      :error -> nil
    end
  end
end
