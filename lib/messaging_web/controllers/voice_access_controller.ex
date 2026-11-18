defmodule MessagingWeb.VoiceAccessController do
  use Phoenix.Controller, formats: [:json]

  alias Messaging.Chat

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
        conn |> put_status(503) |> json(%{"allowed" => false})

      _ ->
        conn |> put_status(403) |> json(%{"allowed" => false})
    end
  end

  def show(conn, _params),
    do: conn |> put_status(400) |> json(%{"allowed" => false})
end
