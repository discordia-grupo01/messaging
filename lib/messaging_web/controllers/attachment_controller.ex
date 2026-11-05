defmodule MessagingWeb.AttachmentController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Messaging.Chat
  alias Messaging.Chat.Attachment
  alias MessagingWeb.ApiError
  alias MessagingWeb.Schemas
  alias OpenApiSpex.Schema

  @read_length 1_000_000
  @read_timeout 30_000

  tags ["attachments"]

  operation :create,
    summary: "Subir un archivo para adjuntarlo a un mensaje",
    description:
      "El cuerpo del pedido es el archivo en binario (no multipart ni base64). Se acepta JPEG, " <>
        "PNG, WebP o PDF de hasta #{div(Attachment.max_bytes(), 1_048_576)} MB, o " <>
        "#{div(Attachment.boosted_max_bytes(), 1_048_576)} MB en un servidor de nivel " <>
        "#{Attachment.boosted_level()} de boosts, o " <>
        "#{div(Attachment.premium_max_bytes(), 1_048_576)} MB con Premium, que también permite " <>
        "GIF; el formato se reconoce por el contenido real del archivo, no por la extensión ni por el " <>
        "`Content-Type`. Indicá el destino con `channel_id` (canal de un servidor) o con `to` " <>
        "(id del usuario, para un mensaje directo), nunca los dos. Hay que tener permiso de " <>
        "escribir ahí. La respuesta trae el `id` que se manda después en `attachment_ids` al " <>
        "enviar el mensaje por el WebSocket (`new_message` o `send_dm`). Un archivo que no se " <>
        "adjunta a ningún mensaje en 24 horas se borra solo. Se pueden adjuntar hasta " <>
        "#{Attachment.max_per_message()} archivos por mensaje.",
    parameters: [
      channel_id: [
        in: :query,
        type: :string,
        required: false,
        description: "Canal de texto de un servidor donde se va a enviar el mensaje"
      ],
      to: [
        in: :query,
        type: :string,
        required: false,
        description: "Id del usuario destinatario de un mensaje directo"
      ],
      filename: [
        in: :query,
        type: :string,
        required: false,
        description: "Nombre con el que se muestra el archivo (máx 100 caracteres)"
      ]
    ],
    request_body:
      {"Contenido del archivo", "application/octet-stream",
       %Schema{type: :string, format: :binary}},
    responses: %{
      201 => {"Archivo subido", "application/json", Schemas.Attachment},
      400 =>
        {"Archivo vacío, destino mal indicado, o demasiados archivos sin enviar",
         "application/json", Schemas.ErrorResponse},
      401 =>
        {"Falta o es inválido el Authorization: Bearer <jwt>", "application/json",
         Schemas.ErrorResponse},
      403 =>
        {"Sin permiso para escribir en ese canal, silenciado, o bloqueado en el mensaje directo",
         "application/json", Schemas.ErrorResponse},
      404 => {"El canal o el destinatario no existen", "application/json", Schemas.ErrorResponse},
      413 => {"El archivo supera el máximo permitido", "application/json", Schemas.ErrorResponse},
      415 => {"Formato no soportado", "application/json", Schemas.ErrorResponse},
      429 =>
        {"Demasiados archivos subidos sin enviar", "application/json", Schemas.ErrorResponse},
      503 => {"No se pudo guardar el archivo", "application/json", Schemas.ErrorResponse}
    }

  def create(conn, params) do
    user_id = conn.assigns.user_id

    with {:ok, target} <- target(params),
         max_bytes = Chat.max_upload_bytes(user_id, target),
         :ok <- check_declared_size(conn, max_bytes),
         {:ok, channel_id} <- Chat.prepare_upload(target, user_id) do
      store(conn, channel_id, user_id, Map.get(params, "filename"), max_bytes)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp store(conn, channel_id, user_id, filename, max_bytes) do
    case read_file(conn, max_bytes) do
      {:ok, body, conn} ->
        case Chat.store_attachment(channel_id, user_id, filename, body) do
          {:ok, attachment} -> conn |> put_status(201) |> json(Attachment.to_api(attachment))
          {:error, reason} -> error(conn, reason)
        end

      {:error, reason, conn} ->
        error(conn, reason)
    end
  end

  defp target(%{"channel_id" => _channel_id, "to" => _to}), do: {:error, :invalid_payload}

  defp target(%{"channel_id" => channel_id}) when is_binary(channel_id) and channel_id != "",
    do: {:ok, {:channel, channel_id}}

  defp target(%{"to" => to}) when is_binary(to) and to != "", do: {:ok, {:direct, to}}
  defp target(_params), do: {:error, :invalid_payload}

  defp check_declared_size(conn, max_bytes) do
    with [raw] <- Plug.Conn.get_req_header(conn, "content-length"),
         {size, ""} <- Integer.parse(raw),
         true <- size > max_bytes do
      {:error, :file_too_large}
    else
      _within_limit -> :ok
    end
  end

  defp read_file(conn, max_bytes) do
    case Plug.Conn.read_body(conn,
           length: max_bytes + 1,
           read_length: @read_length,
           read_timeout: @read_timeout
         ) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, conn} -> {:error, :file_too_large, conn}
      {:error, _reason} -> {:error, :invalid_payload, conn}
    end
  end

  defp error(conn, reason),
    do: conn |> put_status(ApiError.http_status(reason)) |> json(ApiError.payload(reason))
end
