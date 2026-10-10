defmodule MessagingWeb.SocketTicketControllerTest do
  use MessagingWeb.ConnCase
  import Mox

  alias Messaging.Auth.TicketStoreMock
  alias Messaging.AuthFixtures

  setup :verify_on_exit!

  test "POST /v1/socket-tickets requires Authorization", %{conn: conn} do
    conn = post(conn, "/v1/socket-tickets")

    assert json_response(conn, 401)["error"]["code"] == "UNAUTHORIZED"
  end

  test "issues a ticket bound to the caller, without keeping their token", %{conn: conn} do
    token = AuthFixtures.token_for("user-1")

    expect(TicketStoreMock, :put, fn doc ->
      assert doc["user_id"] == "user-1"
      refute Map.has_key?(doc, "raw_jwt")
      :ok
    end)

    conn =
      conn
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
      |> post("/v1/socket-tickets")

    assert %{"ticket" => ticket, "expires_in" => 30} = json_response(conn, 201)
    assert is_binary(ticket) and ticket != ""
  end

  test "503s when the ticket cannot be stored", %{conn: conn} do
    expect(TicketStoreMock, :put, fn _doc -> {:error, :mongo_down} end)

    conn =
      conn
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> AuthFixtures.token_for("user-1"))
      |> post("/v1/socket-tickets")

    assert json_response(conn, 503)["error"]["code"] == "TICKET_UNAVAILABLE"
  end
end
