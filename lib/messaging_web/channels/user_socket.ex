defmodule MessagingWeb.UserSocket do
  use Phoenix.Socket

  alias Messaging.Auth.SocketTicket

  channel "channel:*", MessagingWeb.RoomChannel
  channel "user:*", MessagingWeb.UserChannel

  @impl true
  def connect(%{"ticket" => ticket}, socket, _connect_info) when is_binary(ticket) do
    case SocketTicket.redeem(ticket) do
      {:ok, %{user_id: user_id, raw_jwt: raw_jwt}} ->
        {:ok, assign(socket, user_id: user_id, raw_jwt: raw_jwt)}

      {:error, :invalid_ticket} ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "user_socket:" <> socket.assigns.user_id
end
