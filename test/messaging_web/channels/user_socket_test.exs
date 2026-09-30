defmodule MessagingWeb.UserSocketTest do
  use MessagingWeb.ChannelCase, async: true

  alias Messaging.AuthFixtures
  alias MessagingWeb.UserSocket

  test "connect/3 accepts a valid token and assigns the user id" do
    token = AuthFixtures.token_for("user-1")

    assert {:ok, socket} = connect(UserSocket, %{"token" => token})
    assert socket.assigns.user_id == "user-1"
    assert socket.assigns.raw_jwt == token
  end

  test "connect/3 rejects a missing token" do
    assert :error = connect(UserSocket, %{})
  end

  test "connect/3 rejects a garbage token" do
    assert :error = connect(UserSocket, %{"token" => "not-a-jwt"})
  end

  test "connect/3 rejects an expired token" do
    token = AuthFixtures.token_for("user-1", ttl: -10)

    assert :error = connect(UserSocket, %{"token" => token})
  end

  test "id/1 namespaces the socket id by user" do
    token = AuthFixtures.token_for("user-1")
    {:ok, socket} = connect(UserSocket, %{"token" => token})

    assert UserSocket.id(socket) == "user_socket:user-1"
  end
end
