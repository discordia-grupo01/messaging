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
        "destinatario. `conversation_id` es opcional: si no se envía, se resuelve la conversación " <>
        "directa existente y se devuelve en la respuesta. En cualquier otro caso responde con el " <>
        "sobre de error y el cliente sólo mira el status.",
    parameters: [
      recipient_id: [
        in: :path,
        schema: %OpenApiSpex.Schema{
          type: :string,
          minLength: 1,
          maxLength: 64,
          pattern: "^[A-Za-z0-9_-]+$"
        },
        required: true,
        description: "Id del destinatario"
      ],
      conversation_id: [
        in: :query,
        type: :string,
        required: false,
        description:
          "Id de la conversación directa; si falta, se resuelve a partir del destinatario"
      ]
    ],
    responses: [
      ok: {"Puede llamar", "application/json", Schemas.VoiceAccess},
      bad_request:
        {"El id del destinatario o la conversación no son válidos", "application/json",
         Schemas.ErrorResponse},
      unauthorized:
        {"Falta o es inválido el Authorization: Bearer <jwt>", "application/json",
         Schemas.ErrorResponse},
      forbidden: {"No puede llamar a ese usuario", "application/json", Schemas.ErrorResponse},
      service_unavailable:
        {"No se pudo verificar al destinatario", "application/json", Schemas.ErrorResponse}
    ]

  def show(conn, %{"recipient_id" => recipient_id} = params)
      when is_binary(recipient_id) do
    conversation_id = Map.get(params, "conversation_id")

    case Chat.authorize_private_voice(conn.assigns.user_id, recipient_id, conversation_id) do
      {:ok, resolved_conversation_id} ->
        json(conn, %{"allowed" => true, "conversation_id" => resolved_conversation_id})

      :ok ->
        response =
          if is_binary(conversation_id) and conversation_id != "" do
            %{"allowed" => true, "conversation_id" => conversation_id}
          else
            %{"allowed" => true}
          end

        json(conn, response)

      {:error, :users_unavailable} ->
        error(conn, :users_unavailable)

      _denied ->
        error(conn, {:forbidden, "No podés llamar a este usuario."})
    end
  end

  def show(conn, _params), do: error(conn, {:invalid_query, "recipient_id"})

  defp error(conn, reason),
    do: conn |> put_status(ApiError.http_status(reason)) |> json(ApiError.payload(reason))
end
