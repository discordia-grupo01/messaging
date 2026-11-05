defmodule MessagingWeb.UploadTicketControllerTest do
  use MessagingWeb.ConnCase
  import Mox

  alias Messaging.Auth.TicketStoreMock
  alias Messaging.AuthFixtures

  setup :verify_on_exit!

  defp authed(conn) do
    Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> AuthFixtures.token_for("user-1"))
  end

  test "requires Authorization", %{conn: conn} do
    conn = post(conn, "/v1/attachment-tickets")

    assert json_response(conn, 401)["error"]["code"] == "UNAUTHORIZED"
  end

  test "issues a ticket bound to the caller", %{conn: conn} do
    expect(TicketStoreMock, :put, fn doc ->
      assert doc["user_id"] == "user-1"
      :ok
    end)

    conn = conn |> authed() |> post("/v1/attachment-tickets")

    assert %{"ticket" => ticket, "expires_in" => 60} = json_response(conn, 201)
    assert is_binary(ticket) and ticket != ""
  end

  test "503s when the ticket cannot be stored", %{conn: conn} do
    expect(TicketStoreMock, :put, fn _doc -> {:error, :mongo_down} end)

    conn = conn |> authed() |> post("/v1/attachment-tickets")

    assert json_response(conn, 503)["error"]["code"] == "TICKET_UNAVAILABLE"
  end
end
