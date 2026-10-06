defmodule MessagingWeb.ApiError do
  @type reason ::
          :empty_content
          | :message_too_long
          | :forbidden
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
          | :invalid_payload

  @spec describe(reason()) :: {String.t(), String.t()}
  def describe(:empty_content), do: {"EMPTY_CONTENT", "El mensaje no puede estar vacío."}

  def describe(:message_too_long),
    do:
      {"MESSAGE_TOO_LONG",
       "El mensaje supera el largo máximo permitido (#{Messaging.Chat.max_message_length()} caracteres)."}

  def describe(:forbidden),
    do: {"FORBIDDEN", "No tenés permiso para realizar esta acción en este canal."}

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

  def describe(:invalid_payload),
    do: {"INVALID_PAYLOAD", "El pedido no tiene el formato esperado."}

  @spec payload(reason(), map()) :: map()
  def payload(reason, details \\ %{}) do
    {code, message} = describe(reason)
    %{error: %{code: code, message: message, details: details}}
  end

  @spec http_status(reason()) :: 400 | 403 | 404 | 503
  def http_status(:forbidden), do: 403
  def http_status(:not_message_author), do: 403
  def http_status(:message_delete_denied), do: 403
  def http_status(:message_not_found), do: 404
  def http_status(:channel_not_found), do: 404
  def http_status(:recipient_not_found), do: 404
  def http_status(:users_unavailable), do: 503
  def http_status(:ticket_unavailable), do: 503
  def http_status(_other), do: 400
end
