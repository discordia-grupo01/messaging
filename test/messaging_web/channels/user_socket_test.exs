defmodule MessagingWeb.UserSocketTest do
  use MessagingWeb.ChannelCase, async: true
  import Mox

  alias Messaging.Auth.TicketStoreMock
  alias Messaging.AuthFixtures
  alias MessagingWeb.UserSocket

  setup :verify_on_exit!

  test "connect/3 accepts a valid ticket and assigns the user id and the original jwt" do
    doc = AuthFixtures.ticket_doc("user-1")
    expect(TicketStoreMock, :take, fn _id -> {:ok, doc} end)

    assert {:ok, socket} = connect(UserSocket, %{"ticket" => "a-ticket"})
    assert socket.assigns.user_id == "user-1"
    assert socket.assigns.raw_jwt == doc["raw_jwt"]
  end

  test "connect/3 rejects a missing ticket" do
    assert :error = connect(UserSocket, %{})
  end

  test "connect/3 no longer accepts a jwt in the url" do
    assert :error = connect(UserSocket, %{"token" => AuthFixtures.token_for("user-1")})
  end

  test "connect/3 rejects an unknown or already used ticket" do
    expect(TicketStoreMock, :take, fn _id -> {:ok, nil} end)

    assert :error = connect(UserSocket, %{"ticket" => "a-ticket"})
  end

  test "connect/3 rejects an expired ticket" do
    expect(TicketStoreMock, :take, fn _id -> {:ok, AuthFixtures.ticket_doc("user-1", ttl: -1)} end)

    assert :error = connect(UserSocket, %{"ticket" => "a-ticket"})
  end

  test "id/1 namespaces the socket id by user" do
    stub(TicketStoreMock, :take, fn _id -> {:ok, AuthFixtures.ticket_doc("user-1")} end)
    {:ok, socket} = connect(UserSocket, %{"ticket" => "a-ticket"})

    assert UserSocket.id(socket) == "user_socket:user-1"
  end
end
