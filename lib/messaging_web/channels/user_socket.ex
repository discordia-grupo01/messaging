defmodule MessagingWeb.UserSocket do
  use Phoenix.Socket

  alias Messaging.Auth.Token

  channel "channel:*", MessagingWeb.RoomChannel

  @dialyzer {:nowarn_function, connect: 3}

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) when is_binary(token) do
    case Token.verify_user_id(token) do
      {:ok, user_id} -> {:ok, assign(socket, user_id: user_id, raw_jwt: token)}
      {:error, _reason} -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "user_socket:" <> socket.assigns.user_id
end
