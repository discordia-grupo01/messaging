defmodule MessagingWeb.HealthControllerTest do
  use MessagingWeb.ConnCase
  import Mox

  setup :verify_on_exit!

  test "GET /livez never touches Mongo and always answers 200", %{conn: conn} do
    conn = get(conn, "/livez")
    assert conn.status == 200
    assert conn.resp_body == "ok"
  end

  test "GET /readyz is 200 when Mongo and Postgres are reachable", %{conn: conn} do
    expect(Messaging.Chat.RepoMock, :ping, fn -> :ok end)
    expect(Messaging.Outbox.StoreMock, :ping, fn -> :ok end)

    conn = get(conn, "/readyz")
    assert json_response(conn, 200) == %{"status" => "ready"}
  end

  test "GET /readyz is 503 when Postgres isn't reachable", %{conn: conn} do
    expect(Messaging.Chat.RepoMock, :ping, fn -> :ok end)
    expect(Messaging.Outbox.StoreMock, :ping, fn -> {:error, :timeout} end)

    conn = get(conn, "/readyz")
    assert json_response(conn, 503) == %{"status" => "unavailable", "detail" => "postgres"}
  end

  test "GET /readyz is 503 when Mongo isn't reachable", %{conn: conn} do
    expect(Messaging.Chat.RepoMock, :ping, fn -> {:error, :timeout} end)

    conn = get(conn, "/readyz")
    assert json_response(conn, 503) == %{"status" => "unavailable", "detail" => "mongo"}
  end
end
