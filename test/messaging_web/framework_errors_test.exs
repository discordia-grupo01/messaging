defmodule MessagingWeb.FrameworkErrorsTest do
  use MessagingWeb.ConnCase

  alias Messaging.AuthFixtures

  @code_regex ~r/^[A-Z][A-Z0-9_]*$/

  defp assert_envelope(body, code) do
    assert %{"error" => %{"code" => ^code, "message" => message, "details" => details}} =
             Jason.decode!(body)

    assert code =~ @code_regex
    assert is_binary(message) and message != ""
    assert is_map(details)
  end

  test "an unknown route answers 404 NOT_FOUND with the envelope", %{conn: conn} do
    conn = get(conn, "/v1/does-not-exist")

    assert {"content-type", "application/json" <> _} =
             List.keyfind(conn.resp_headers, "content-type", 0)

    assert_envelope(response(conn, 404), "NOT_FOUND")
  end

  test "a malformed JSON body answers 400 INVALID_BODY with the envelope" do
    conn =
      build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> AuthFixtures.token_for("user-1"))
      |> Plug.Conn.put_req_header("content-type", "application/json")

    {400, _headers, body} =
      assert_error_sent(400, fn -> post(conn, "/v1/blocks", "{not json") end)

    assert_envelope(body, "INVALID_BODY")
  end

  test "a missing token answers 401 UNAUTHORIZED with the envelope", %{conn: conn} do
    conn = get(conn, "/v1/blocks")
    assert_envelope(response(conn, 401), "UNAUTHORIZED")
  end

  test "a missing upload ticket answers 401 UNAUTHORIZED with the envelope", %{conn: conn} do
    conn =
      conn
      |> Plug.Conn.put_req_header("content-type", "application/octet-stream")
      |> post("/v1/attachments/direct", "x")

    assert_envelope(response(conn, 401), "UNAUTHORIZED")
  end

  test "an unexpected exception answers 500 INTERNAL_ERROR without leaking it" do
    Mox.expect(Messaging.Chat.RepoMock, :list_blocks, fn _id, _limit -> raise "boom secreto" end)

    conn =
      Plug.Conn.put_req_header(
        build_conn(),
        "authorization",
        "Bearer " <> AuthFixtures.token_for("user-1")
      )

    {500, _headers, body} = assert_error_sent(500, fn -> get(conn, "/v1/blocks") end)

    assert_envelope(body, "INTERNAL_ERROR")
    refute body =~ "boom"
  end
end
