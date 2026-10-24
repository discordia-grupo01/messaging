defmodule MessagingWeb.MessageController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias Messaging.Chat
  alias Messaging.Chat.Message
  alias MessagingWeb.ApiError
  alias MessagingWeb.Schemas

  tags ["messages"]

  operation :index,
    summary: "Historial de mensajes de un canal",
    description:
      "Cada página viene en orden cronológico (del más viejo al más nuevo). Sin cursor devuelve " <>
        "los mensajes más recientes; con `before` devuelve los anteriores a ese mensaje; con " <>
        "`after` devuelve los posteriores (para ponerse al día tras una desconexión); con " <>
        "`around` devuelve el historial alrededor de ese mensaje, incluido él (para saltar a " <>
        "un resultado de la búsqueda), y la respuesta trae además `newer_cursor`. " <>
        "`before`, `after` y `around` son excluyentes.",
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
        description: "Id de mensaje devuelto como next_cursor al pedir la página anterior"
      ],
      after: [
        in: :query,
        type: :string,
        required: false,
        description: "Id del último mensaje que el cliente ya tiene; devuelve los posteriores"
      ],
      around: [
        in: :query,
        type: :string,
        required: false,
        description:
          "Id de un mensaje: devuelve hasta limit/2 mensajes antes y después de él, y el mensaje"
      ]
    ],
    responses: [
      ok: {"Página de mensajes en orden cronológico", "application/json", Schemas.MessageList},
      bad_request:
        {"Cursor inválido, de otro canal, o más de uno entre `before`, `after` y `around`",
         "application/json", Schemas.ErrorResponse},
      unauthorized:
        {"Falta o es inválido el Authorization: Bearer <jwt>", "application/json",
         Schemas.ErrorResponse},
      forbidden:
        {"El usuario no tiene VIEW_CHANNELS en este canal", "application/json",
         Schemas.ErrorResponse},
      not_found:
        {"El canal no existe, o el mensaje de `around` no existe o fue eliminado",
         "application/json", Schemas.ErrorResponse}
    ]

  def index(conn, %{"channel_id" => channel_id} = params) do
    user_id = conn.assigns.user_id
    limit = params |> Map.get("limit") |> parse_limit()

    with {:ok, channel} <- Chat.channel_exists?(channel_id),
         {:ok, true} <- Chat.can_view_channel?(channel, user_id),
         {:ok, messages, cursors} <- fetch_page(channel_id, params, limit),
         {:ok, reactions} <- Chat.reactions_for(messages, user_id) do
      messages = Enum.map(messages, &Message.to_api(&1, reactions))
      json(conn, Map.put(cursors, "messages", messages))
    else
      {:ok, false} ->
        conn |> put_status(403) |> json(ApiError.payload(:forbidden))

      {:error, reason} ->
        conn |> put_status(ApiError.http_status(reason)) |> json(ApiError.payload(reason))
    end
  end

  operation :update,
    summary: "Editar un mensaje propio",
    description:
      "Solo el autor puede editarlo y tiene que seguir pudiendo escribir en el canal " <>
        "(`SEND_MESSAGES`). El contenido nuevo pasa las mismas reglas que al enviar (se recorta, " <>
        "no puede quedar vacío ni superar los 2000 caracteres). Si queda igual al actual no se " <>
        "marca como editado ni se emite nada. Al editar, el mensaje completo se emite en tiempo " <>
        "real a los miembros con el canal abierto como evento `message_updated`.",
    parameters: [
      channel_id: [in: :path, type: :string, required: true, description: "UUID del canal"],
      message_id: [in: :path, type: :string, required: true, description: "UUID del mensaje"]
    ],
    request_body: {"Contenido nuevo", "application/json", Schemas.EditMessageRequest},
    responses: [
      ok: {"El mensaje, ya editado", "application/json", Schemas.Message},
      bad_request:
        {"Contenido vacío, demasiado largo o con palabras prohibidas (`BANNED_WORD`), o cuerpo mal formado",
         "application/json", Schemas.ErrorResponse},
      unauthorized:
        {"Falta o es inválido el Authorization: Bearer <jwt>", "application/json",
         Schemas.ErrorResponse},
      forbidden:
        {"No es el autor del mensaje, o no tiene SEND_MESSAGES en el canal", "application/json",
         Schemas.ErrorResponse},
      not_found: {"El canal o el mensaje no existen", "application/json", Schemas.ErrorResponse}
    ]

  def update(conn, %{"channel_id" => channel_id, "message_id" => message_id} = params) do
    with {:ok, content} <- fetch_content(params),
         {:ok, message, _change} <-
           Chat.edit_message(%{
             channel_id: channel_id,
             message_id: message_id,
             user_id: conn.assigns.user_id,
             content: content
           }) do
      json(conn, Message.to_api(message))
    else
      {:error, reason} ->
        conn |> put_status(ApiError.http_status(reason)) |> json(ApiError.payload(reason))
    end
  end

  operation :delete,
    summary: "Eliminar un mensaje",
    description:
      "Lo puede eliminar su autor o un miembro con `MANAGE_MESSAGES` en el canal (los " <>
        "administradores lo tienen implícito). Quien elimina tiene que poder ver el canal " <>
        "(`VIEW_CHANNELS`). El mensaje deja de aparecer en el historial y su contenido se borra; " <>
        "se emite en tiempo real a los miembros con el canal abierto como evento " <>
        "`message_deleted`, y los clientes desconectados lo reciben al reconectar en " <>
        "`changed_messages.deleted_ids`. Eliminar un mensaje ya eliminado responde 404.",
    parameters: [
      channel_id: [in: :path, type: :string, required: true, description: "UUID del canal"],
      message_id: [in: :path, type: :string, required: true, description: "UUID del mensaje"]
    ],
    responses: [
      no_content: "Mensaje eliminado",
      unauthorized:
        {"Falta o es inválido el Authorization: Bearer <jwt>", "application/json",
         Schemas.ErrorResponse},
      forbidden:
        {"No es el autor ni tiene MANAGE_MESSAGES, o no puede ver el canal", "application/json",
         Schemas.ErrorResponse},
      not_found:
        {"El canal o el mensaje no existen (o ya fue eliminado)", "application/json",
         Schemas.ErrorResponse}
    ]

  def delete(conn, %{"channel_id" => channel_id, "message_id" => message_id}) do
    case Chat.delete_message(%{
           channel_id: channel_id,
           message_id: message_id,
           user_id: conn.assigns.user_id
         }) do
      {:ok, _message} ->
        send_resp(conn, 204, "")

      {:error, reason} ->
        conn |> put_status(ApiError.http_status(reason)) |> json(ApiError.payload(reason))
    end
  end

  defp fetch_page(channel_id, %{"around" => around_id} = params, limit) do
    if Map.has_key?(params, "before") or Map.has_key?(params, "after") do
      {:error, :invalid_cursor}
    else
      with {:ok, messages, older, newer} <-
             Chat.list_messages_around(channel_id, around_id, limit: limit) do
        {:ok, messages, %{"next_cursor" => older, "newer_cursor" => newer}}
      end
    end
  end

  defp fetch_page(channel_id, params, limit) do
    opts = [limit: limit, before: Map.get(params, "before"), after: Map.get(params, "after")]

    with {:ok, messages, next_cursor} <- Chat.list_messages(channel_id, opts) do
      {:ok, messages, %{"next_cursor" => next_cursor}}
    end
  end

  defp fetch_content(%{"content" => content}) when is_binary(content), do: {:ok, content}
  defp fetch_content(_params), do: {:error, :invalid_payload}

  defp parse_limit(nil), do: nil

  defp parse_limit(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, _rest} -> n
      :error -> nil
    end
  end
end
