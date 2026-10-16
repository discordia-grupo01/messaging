defmodule MessagingWeb.ApiError do
  @type reason ::
          :empty_content
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
          | :file_too_large
          | :unsupported_file_type
          | :empty_file
          | :too_many_attachments
          | :invalid_attachment
          | :too_many_pending_attachments
          | :storage_unavailable
          | :messages_unavailable
          | :account_suspended
          | :suspension_unavailable

  @spec describe(reason()) :: {String.t(), String.t()}
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
    do: {"INVALID_PAYLOAD", "El pedido no tiene el formato esperado."}

  def describe(:invalid_emoji), do: {"INVALID_EMOJI", "La reacción tiene que ser un solo emoji."}

  def describe(:too_many_reactions),
    do:
      {"TOO_MANY_REACTIONS",
       "El mensaje ya tiene el máximo de #{Messaging.Chat.Reaction.max_per_message()} reacciones distintas."}

  def describe(:file_too_large),
    do:
      {"FILE_TOO_LARGE",
       "El archivo supera el tamaño máximo permitido (#{div(Messaging.Chat.Attachment.max_bytes(), 1_048_576)} MB)."}

  def describe(:unsupported_file_type),
    do:
      {"UNSUPPORTED_FILE_TYPE",
       "Formato no soportado. Solo se aceptan imágenes JPEG, PNG o WebP y archivos PDF."}

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

  def describe(:suspension_unavailable),
    do:
      {"SUSPENSION_UNAVAILABLE",
       "No se pudo verificar el estado de tu cuenta, intentá de nuevo en un momento."}

  def describe({:banned_word, _words}),
    do: {"BANNED_WORD", "El mensaje contiene palabras prohibidas en este servidor."}

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

  @spec http_status(reason()) :: 400 | 403 | 404 | 413 | 415 | 429 | 503
  def http_status(:account_suspended), do: 403
  def http_status(:suspension_unavailable), do: 503
  def http_status(:forbidden), do: 403
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
  def http_status(:file_too_large), do: 413
  def http_status(:unsupported_file_type), do: 415
  def http_status(:too_many_pending_attachments), do: 429
  def http_status(_other), do: 400
end
