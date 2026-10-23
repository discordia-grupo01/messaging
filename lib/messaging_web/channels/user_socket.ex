defmodule MessagingWeb.UserSocket do
  use Phoenix.Socket

  alias Messaging.Auth.SocketTicket
  alias Messaging.Suspension

  channel "channel:*", MessagingWeb.RoomChannel
  channel "user:*", MessagingWeb.UserChannel
  channel "presence:*", MessagingWeb.PresenceChannel

  @impl true
  def connect(%{"ticket" => ticket}, socket, _connect_info) when is_binary(ticket) do
    case SocketTicket.redeem(ticket) do
      {:ok, %{user_id: user_id}} ->
        connect_active(socket, user_id)

      {:error, :invalid_ticket} ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  # A ticket issued before the suspension lives 30 s: it must not open a socket.
  defp connect_active(socket, user_id) do
    case Suspension.ensure_active(user_id) do
      :ok -> {:ok, assign(socket, user_id: user_id)}
      {:error, _reason} -> :error
    end
  end

  @impl true
  def id(socket), do: "user_socket:" <> socket.assigns.user_id
end
