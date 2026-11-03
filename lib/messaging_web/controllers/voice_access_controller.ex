defmodule MessagingWeb.VoiceAccessController do
  use Phoenix.Controller, formats: [:json]

  alias Messaging.Chat

  def show(conn, %{"recipient_id" => recipient_id, "conversation_id" => conversation_id})
      when is_binary(recipient_id) and is_binary(conversation_id) do
    case Chat.authorize_private_voice(conn.assigns.user_id, recipient_id, conversation_id) do
      :ok -> json(conn, %{"allowed" => true})
      {:error, :users_unavailable} -> conn |> put_status(503) |> json(%{"allowed" => false})
      _ -> conn |> put_status(403) |> json(%{"allowed" => false})
    end
  end

  def show(conn, _params),
    do: conn |> put_status(400) |> json(%{"allowed" => false})
end
