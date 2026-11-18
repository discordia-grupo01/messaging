defmodule MessagingWeb.ApiError do
  @moduledoc """
  Único punto que arma el sobre de error `{"error": {"code", "message", "details"}}`.

  `code` es siempre un string SCREAMING_SNAKE; `details` es siempre un objeto. Los códigos
  genéricos (`INVALID_BODY`, `NOT_FOUND`, `INTERNAL_ERROR`, ...) son los del catálogo común de
  la plataforma; el resto son códigos de dominio.
  """

  require Logger

  @type reason ::
          :unauthorized
          | {:unauthorized, String.t()}
          | {:forbidden, String.t()}
          | {:invalid_query, String.t()}
          | :service_unavailable
          | :empty_content
          | :message_too_long
          | :forbidden
          | :member_muted
          | :channel_not_found
          | :channel_not_text
          | :invalid_cursor
          | :ticket_unavailable
          | :message_not_found
          | :not_message_author
          | :message_delete_denied
          | :cannot_message_self
          | :recipient_not_found
          | :users_unavailable
          | :mentions_unavailable
          | :cannot_block_self
          | :user_not_found
          | :user_blocked
          | :dm_not_delivered
          | :invalid_payload
          | {:banned_word, [String.t()]}
          | :invalid_emoji
          | :too_many_reactions
          | :custom_emoji_not_allowed
          | :custom_emojis_unavailable
          | :too_many_custom_emojis
          | :file_too_large
          | :unsupported_file_type
          | :empty_file
          | :too_many_attachments
          | :invalid_attachment
          | :too_many_pending_attachments
          | :storage_unavailable
          | :messages_unavailable
          | :account_suspended
          | :server_suspended
          | :suspension_unavailable
          | :invalid_status
          | :presence_unavailable
          | :invalid_search_query
          | :not_server_member
          | :search_unavailable

  @spec describe(reason() | term()) :: {String.t(), String.t()}
  def describe(:unauthorized), do: describe({:unauthorized, "Token inválido o ausente."})
  def describe({:unauthorized, message}), do: {"UNAUTHORIZED", message}
  def describe({:forbidden, message}), do: {"FORBIDDEN", message}

  def describe({:invalid_query, param}),
    do: {"INVALID_QUERY", "El parámetro de query #{param} es inválido o falta."}

  def describe(:service_unavailable),
    do:
      {"SERVICE_UNAVAILABLE",
       "No se pudo completar la operación, intentá de nuevo en un momento."}

  def describe(:empty_content), do: {"EMPTY_CONTENT", "El mensaje no puede estar vacío."}

  def describe(:message_too_long),
    do:
      {"MESSAGE_TOO_LONG",
       "El mensaje supera el largo máximo permitido (#{Messaging.Chat.max_message_length()} caracteres)."}

  def describe(:forbidden),
    do: {"FORBIDDEN", "No tenés permiso para realizar esta acción en este canal."}

  def describe(:member_muted),
    do: {"MEMBER_MUTED", "No podés enviar mensajes mientras estás silenciado."}

  def describe(:channel_not_found), do: {"CHANNEL_NOT_FOUND", "El canal no existe."}

  def describe(:channel_not_text),
    do: {"CHANNEL_NOT_TEXT", "Solo se pueden enviar mensajes en canales de texto."}

  def describe(:invalid_cursor), do: {"INVALID_CURSOR", "El cursor de paginación no es válido."}

  def describe(:ticket_unavailable),
    do: {"TICKET_UNAVAILABLE", "No se pudo emitir el ticket, intentá de nuevo."}

  def describe(:message_not_found), do: {"MESSAGE_NOT_FOUND", "El mensaje no existe."}

  def describe(:not_message_author),
    do: {"NOT_MESSAGE_AUTHOR", "Solo el autor de un mensaje puede editarlo."}

  def describe(:message_delete_denied),
    do:
      {"MESSAGE_DELETE_DENIED",
       "Solo el autor del mensaje o un miembro con permiso de gestión de mensajes puede eliminarlo."}

  def describe(:cannot_message_self),
    do: {"CANNOT_MESSAGE_SELF", "No podés enviarte mensajes directos a vos mismo."}

  def describe(:recipient_not_found), do: {"RECIPIENT_NOT_FOUND", "El destinatario no existe."}

  def describe(:users_unavailable),
    do:
      {"USERS_UNAVAILABLE",
       "No se pudo verificar al destinatario, intentá de nuevo en un momento."}

  def describe(:mentions_unavailable),
    do:
      {"MENTIONS_UNAVAILABLE",
       "No se pudieron verificar las menciones del mensaje, intentá de nuevo en un momento."}

  def describe(:cannot_block_self),
    do: {"CANNOT_BLOCK_SELF", "No podés bloquearte a vos mismo."}

  def describe(:user_not_found), do: {"USER_NOT_FOUND", "El usuario no existe."}

  def describe(:user_blocked),
    do: {"USER_BLOCKED", "Bloqueaste a este usuario: desbloquealo para escribirle."}

  def describe(:dm_not_delivered),
    do: {"DM_NOT_DELIVERED", "No se pudo entregar el mensaje."}

  def describe(:invalid_payload),
    do: {"INVALID_BODY", "El pedido no tiene el formato esperado."}

  def describe(:invalid_emoji), do: {"INVALID_EMOJI", "La reacción tiene que ser un solo emoji."}

  def describe(:too_many_reactions),
    do:
      {"TOO_MANY_REACTIONS",
       "El mensaje ya tiene el máximo de #{Messaging.Chat.Reaction.max_per_message()} reacciones distintas."}

  def describe(:file_too_large),
    do:
      {"FILE_TOO_LARGE",
       "El archivo supera el tamaño máximo permitido (#{div(Messaging.Chat.Attachment.max_bytes(), 1_048_576)} MB, #{div(Messaging.Chat.Attachment.boosted_max_bytes(), 1_048_576)} MB en un servidor de nivel #{Messaging.Chat.Attachment.boosted_level()}, o #{div(Messaging.Chat.Attachment.premium_max_bytes(), 1_048_576)} MB con Premium)."}

  def describe(:unsupported_file_type),
    do:
      {"UNSUPPORTED_FILE_TYPE",
       "Formato no soportado. Solo se aceptan imágenes JPEG, PNG o WebP y archivos PDF (y GIF con Premium)."}

  def describe(:empty_file),
    do: {"EMPTY_FILE", "El archivo está vacío: mandalo como cuerpo binario del pedido."}

  def describe(:too_many_attachments),
    do:
      {"TOO_MANY_ATTACHMENTS",
       "Un mensaje puede tener hasta #{Messaging.Chat.Attachment.max_per_message()} adjuntos."}

  def describe(:invalid_attachment),
    do:
      {"INVALID_ATTACHMENT",
       "Algún adjunto no existe, ya se usó en otro mensaje, es de otro canal o no es tuyo."}

  def describe(:too_many_pending_attachments),
    do:
      {"TOO_MANY_PENDING_ATTACHMENTS",
       "Tenés demasiados adjuntos subidos sin enviar (máximo #{Messaging.Chat.Attachment.max_pending_per_user()}). Enviá los mensajes o esperá un rato."}

  def describe(:storage_unavailable),
    do: {"STORAGE_UNAVAILABLE", "No se pudo guardar el archivo, intentá de nuevo en un momento."}

  def describe(:messages_unavailable),
    do:
      {"MESSAGES_UNAVAILABLE", "No se pudo registrar el mensaje, intentá de nuevo en un momento."}

  def describe(:account_suspended),
    do: {"ACCOUNT_SUSPENDED", "Tu cuenta está suspendida: no podés realizar acciones."}

  def describe(:server_suspended),
    do:
      {"SERVER_SUSPENDED",
       "Este servidor está suspendido por el staff de la plataforma: no se puede usar hasta que lo reactiven."}

  def describe(:suspension_unavailable),
    do:
      {"SUSPENSION_UNAVAILABLE",
       "No se pudo verificar el estado de tu cuenta, intentá de nuevo en un momento."}

  def describe(:invalid_status),
    do: {"INVALID_STATUS", "El estado tiene que ser online, idle, dnd (no molestar) o invisible."}

  def describe(:presence_unavailable),
    do:
      {"PRESENCE_UNAVAILABLE",
       "No se pudo actualizar tu estado de actividad, intentá de nuevo en un momento."}

  def describe(:invalid_search_query),
    do:
      {"INVALID_SEARCH_QUERY",
       "Ingresá un término de hasta #{Messaging.Chat.Search.max_text_length()} caracteres o elegí un autor para buscar."}

  def describe(:custom_emoji_not_allowed),
    do:
      {"CUSTOM_EMOJI_NOT_ALLOWED",
       "No podés usar ese emoji: tiene que existir y ser de un servidor donde seas miembro. Los animados, los de otro servidor y los que se usan en mensajes directos requieren Premium."}

  def describe(:custom_emojis_unavailable),
    do:
      {"CUSTOM_EMOJIS_UNAVAILABLE",
       "No se pudieron verificar los emojis, intentá de nuevo en un momento."}

  def describe(:too_many_custom_emojis),
    do:
      {"TOO_MANY_CUSTOM_EMOJIS",
       "Podés pedir hasta #{Messaging.Chat.CustomEmoji.max_ids()} emojis por consulta."}

  def describe(:not_server_member),
    do: {"NOT_SERVER_MEMBER", "No sos miembro de este servidor."}

  def describe(:search_unavailable),
    do:
      {"SEARCH_UNAVAILABLE", "No se pudo completar la búsqueda, intentá de nuevo en un momento."}

  def describe({:banned_word, _words}),
    do: {"BANNED_WORD", "El mensaje contiene palabras prohibidas en este servidor."}

  # Error desconocido (por ejemplo un `%Mongo.Error{}` crudo de una dependencia): nunca debe
  # romper el mapper ni filtrar el error interno al cliente; queda sólo en el log.
  def describe(unknown) do
    Logger.error("unmapped_api_error", reason: inspect(unknown))
    describe(:service_unavailable)
  end

  @doc """
  Código genérico del catálogo común para un status HTTP del framework (render_errors).
  """
  @spec code_for_status(integer()) :: String.t()
  def code_for_status(400), do: "INVALID_BODY"
  def code_for_status(401), do: "UNAUTHORIZED"
  def code_for_status(403), do: "FORBIDDEN"
  def code_for_status(404), do: "NOT_FOUND"
  def code_for_status(405), do: "METHOD_NOT_ALLOWED"
  def code_for_status(406), do: "NOT_ACCEPTABLE"
  def code_for_status(413), do: "PAYLOAD_TOO_LARGE"
  def code_for_status(415), do: "UNSUPPORTED_MEDIA_TYPE"
  def code_for_status(_other), do: "INTERNAL_ERROR"

  @spec payload(reason(), map()) :: map()
  def payload(reason, details \\ %{})

  def payload({:banned_word, words} = reason, details) do
    {code, message} = describe(reason)
    %{error: %{code: code, message: message, details: Map.put(details, :words, words)}}
  end

  def payload(reason, details) do
    {code, message} = describe(reason)
    %{error: %{code: code, message: message, details: details}}
  end

  @bad_request [
    :empty_content,
    :message_too_long,
    :channel_not_text,
    :invalid_cursor,
    :cannot_message_self,
    :cannot_block_self,
    :invalid_payload,
    :invalid_emoji,
    :too_many_reactions,
    :empty_file,
    :too_many_attachments,
    :invalid_attachment,
    :invalid_status,
    :invalid_search_query
  ]

  @spec http_status(reason() | term()) :: 400 | 401 | 403 | 404 | 413 | 415 | 429 | 503
  def http_status(:account_suspended), do: 403
  def http_status(:server_suspended), do: 403
  def http_status(:suspension_unavailable), do: 503
  def http_status(:forbidden), do: 403
  def http_status(:custom_emoji_not_allowed), do: 403
  def http_status(:custom_emojis_unavailable), do: 503
  def http_status(:too_many_custom_emojis), do: 400
  def http_status(:member_muted), do: 403
  def http_status(:not_message_author), do: 403
  def http_status(:message_delete_denied), do: 403
  def http_status(:message_not_found), do: 404
  def http_status(:channel_not_found), do: 404
  def http_status(:recipient_not_found), do: 404
  def http_status(:user_not_found), do: 404
  def http_status(:user_blocked), do: 403
  def http_status(:dm_not_delivered), do: 403
  def http_status(:users_unavailable), do: 503
  def http_status(:mentions_unavailable), do: 503
  def http_status(:ticket_unavailable), do: 503
  def http_status(:storage_unavailable), do: 503
  def http_status(:messages_unavailable), do: 503
  def http_status(:presence_unavailable), do: 503
  def http_status(:not_server_member), do: 403
  def http_status(:search_unavailable), do: 503
  def http_status(:file_too_large), do: 413
  def http_status(:unsupported_file_type), do: 415
  def http_status(:too_many_pending_attachments), do: 429
  def http_status(:unauthorized), do: 401
  def http_status({:unauthorized, _message}), do: 401
  def http_status({:forbidden, _message}), do: 403
  def http_status({:invalid_query, _param}), do: 400
  def http_status(:service_unavailable), do: 503
  def http_status({:banned_word, _words}), do: 400
  def http_status(reason) when reason in @bad_request, do: 400
  # Error de una dependencia sin mapear (p. ej. `%Mongo.Error{}`): se trata como no disponible.
  def http_status(_unknown), do: 503
end
