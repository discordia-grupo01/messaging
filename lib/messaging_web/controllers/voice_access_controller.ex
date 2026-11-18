defmodule MessagingWeb.VoiceAccessController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Messaging.Chat
  alias MessagingWeb.ApiError
  alias MessagingWeb.Schemas

  tags ["voice"]

  operation :show,
    summary: "Autorización de llamada privada de voz",
    description:
      "Lo consume el servicio de señalización de voz antes de admitir a un usuario en una " <>
        "llamada privada: responde 200 `{\"allowed\": true}` si el usuario puede llamar al " <>
        "destinatario en esa conversación. En cualquier otro caso responde con el sobre de error " <>
        "y el cliente sólo mira el status.",
    parameters: [
      recipient_id: [in: :path, type: :string, required: true, description: "Id del destinatario"],
      conversation_id: [
        in: :query,
        type: :string,
        required: true,
        description: "Id de la conversación directa"
      ]
    ],
    responses: [
      ok: {"Puede llamar", "application/json", Schemas.VoiceAccess},
      bad_request: {"Falta `conversation_id`", "application/json", Schemas.ErrorResponse},
      unauthorized:
        {"Falta o es inválido el Authorization: Bearer <jwt>", "application/json",
         Schemas.ErrorResponse},
      forbidden:
        {"No puede llamar a ese usuario en esa conversación", "application/json",
         Schemas.ErrorResponse},
      service_unavailable:
        {"No se pudo verificar al destinatario", "application/json", Schemas.ErrorResponse}
    ]

  def show(conn, %{"recipient_id" => recipient_id, "conversation_id" => conversation_id})
      when is_binary(recipient_id) and is_binary(conversation_id) do
    case Chat.authorize_private_voice(conn.assigns.user_id, recipient_id, conversation_id) do
      :ok -> json(conn, %{"allowed" => true})
      {:error, :users_unavailable} -> error(conn, :users_unavailable)
      _denied -> error(conn, {:forbidden, "No podés llamar a este usuario."})
    end
  end

  def show(conn, _params), do: error(conn, {:invalid_query, "conversation_id"})

  defp error(conn, reason),
    do: conn |> put_status(ApiError.http_status(reason)) |> json(ApiError.payload(reason))
end
