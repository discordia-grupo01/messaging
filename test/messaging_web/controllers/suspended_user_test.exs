defmodule MessagingWeb.SuspendedUserTest do
  @moduledoc """
  A suspended user gets `403 ACCOUNT_SUSPENDED` on every authenticated endpoint,
  before the controller touches anything: the repo mock has no other expectation.
  """
  use MessagingWeb.ConnCase
  import Mox

  alias Messaging.AuthFixtures
  alias Messaging.SuspensionHelper

  setup :verify_on_exit!

  @me "11111111-1111-4111-8111-111111111111"
  @other "22222222-2222-4222-8222-222222222222"

  @endpoints [
    {:get, "/v1/channels/chan-1/messages"},
    {:patch, "/v1/channels/chan-1/messages/m1"},
    {:delete, "/v1/channels/chan-1/messages/m1"},
    {:post, "/v1/channels/chan-1/mentions/read"},
    {:get, "/v1/mentions"},
    {:get, "/v1/conversations"},
    {:post, "/v1/conversations/c1/read"},
    {:get, "/v1/blocks"},
    {:post, "/v1/blocks"},
    {:delete, "/v1/blocks/#{@other}"},
    {:post, "/v1/socket-tickets"},
    {:post, "/v1/attachments?channel_id=chan-1"}
  ]

  defp authed(conn, user_id) do
    Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> AuthFixtures.token_for(user_id))
  end

  for {method, path} <- @endpoints do
    test "#{method} #{path} answers 403 ACCOUNT_SUSPENDED", %{conn: conn} do
      SuspensionHelper.stub_suspended(@me)

      conn = conn |> authed(@me) |> dispatch(@endpoint, unquote(method), unquote(path), %{})

      assert %{
               "error" => %{
                 "code" => "ACCOUNT_SUSPENDED",
                 "message" => message,
                 "details" => %{}
               }
             } = json_response(conn, 403)

      assert is_binary(message)
    end

    test "#{method} #{path} answers 503 SUSPENSION_UNAVAILABLE when the state cannot be read",
         %{conn: conn} do
      SuspensionHelper.stub_suspension_check_failing()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn = conn |> authed(@me) |> dispatch(@endpoint, unquote(method), unquote(path), %{})

          assert json_response(conn, 503)["error"]["code"] == "SUSPENSION_UNAVAILABLE"
        end)

      assert log =~ "suspension_check_failed"
    end
  end

  test "reading the history is blocked too", %{conn: conn} do
    SuspensionHelper.stub_suspended(@me)

    conn = conn |> authed(@me) |> get("/v1/channels/chan-1/messages")

    assert json_response(conn, 403)["error"]["code"] == "ACCOUNT_SUSPENDED"
  end

  test "an invalid token is still 401, not 403", %{conn: conn} do
    SuspensionHelper.stub_suspended(@me)

    conn = get(conn, "/v1/mentions")

    assert json_response(conn, 401)["error"]["code"] == "UNAUTHORIZED"
  end

  test "another user is not affected by someone else's suspension", %{conn: conn} do
    SuspensionHelper.stub_suspended(@me)
    stub(Messaging.Chat.RepoMock, :list_unread_mentions, fn @other, _limit -> {:ok, []} end)

    conn = conn |> authed(@other) |> get("/v1/mentions")

    assert json_response(conn, 200)
  end

  test "liveness and readiness stay open", %{conn: conn} do
    SuspensionHelper.stub_suspended(@me)
    stub(Messaging.Chat.RepoMock, :ping, fn -> :ok end)

    assert conn |> get("/livez") |> response(200)
  end
end
