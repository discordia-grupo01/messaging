defmodule MessagingWeb.MessageControllerTest do
  use MessagingWeb.ConnCase
  import Mox

  alias Messaging.AuthFixtures

  setup :verify_on_exit!

  @channel_id "chan-1"
  @server_id "srv-1"

  defp text_channel_doc,
    do: %{"_id" => @channel_id, "server_id" => @server_id, "name" => "general", "kind" => "text"}

  defp authed(conn, user_id \\ "user-1") do
    Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> AuthFixtures.token_for(user_id))
  end

  test "GET /v1/channels/:channel_id/messages requires Authorization", %{conn: conn} do
    conn = get(conn, "/v1/channels/#{@channel_id}/messages")
    assert json_response(conn, 401)["error"]["code"] == "UNAUTHORIZED"
  end

  test "401s on a malformed Authorization header (no Bearer prefix)", %{conn: conn} do
    conn =
      conn
      |> Plug.Conn.put_req_header("authorization", "Basic dXNlcjpwYXNz")
      |> get("/v1/channels/#{@channel_id}/messages")

    assert json_response(conn, 401)["error"]["code"] == "UNAUTHORIZED"
  end

  test "401s on an invalid bearer token", %{conn: conn} do
    conn =
      conn
      |> Plug.Conn.put_req_header("authorization", "Bearer not-a-jwt")
      |> get("/v1/channels/#{@channel_id}/messages")

    assert json_response(conn, 401)["error"]["code"] == "UNAUTHORIZED"
  end

  test "returns the channel's messages, newest first", %{conn: conn} do
    expect(Messaging.Chat.RepoMock, :get_channel, fn @channel_id -> text_channel_doc() end)

    expect(Messaging.Chat.PermissionsClientMock, :can_send_messages?, fn @server_id,
                                                                         "user-1",
                                                                         _jwt ->
      {:ok, true}
    end)

    doc = %{
      "_id" => "msg-1",
      "channel_id" => @channel_id,
      "server_id" => @server_id,
      "user_id" => "user-1",
      "content" => "hola",
      "inserted_at" => ~U[2026-09-28 12:00:00Z]
    }

    expect(Messaging.Chat.RepoMock, :list_messages, fn @channel_id, _opts -> {:ok, [doc]} end)

    conn = conn |> authed() |> get("/v1/channels/#{@channel_id}/messages")

    assert %{"messages" => [%{"id" => "msg-1", "content" => "hola"}], "next_cursor" => nil} =
             json_response(conn, 200)
  end

  test "403s when the caller lacks SEND_MESSAGES", %{conn: conn} do
    expect(Messaging.Chat.RepoMock, :get_channel, fn @channel_id -> text_channel_doc() end)

    expect(Messaging.Chat.PermissionsClientMock, :can_send_messages?, fn _sid, _uid, _jwt ->
      {:ok, false}
    end)

    conn = conn |> authed() |> get("/v1/channels/#{@channel_id}/messages")

    assert json_response(conn, 403)["error"]["code"] == "FORBIDDEN"
  end

  test "404s for a channel that doesn't exist", %{conn: conn} do
    expect(Messaging.Chat.RepoMock, :get_channel, fn "missing" -> nil end)

    conn = conn |> authed() |> get("/v1/channels/missing/messages")

    assert json_response(conn, 404)["error"]["code"] == "CHANNEL_NOT_FOUND"
  end

  test "400s on an unknown `before` cursor", %{conn: conn} do
    expect(Messaging.Chat.RepoMock, :get_channel, fn @channel_id -> text_channel_doc() end)

    expect(Messaging.Chat.PermissionsClientMock, :can_send_messages?, fn _sid, _uid, _jwt ->
      {:ok, true}
    end)

    expect(Messaging.Chat.RepoMock, :get_message, fn "does-not-exist" -> nil end)

    conn = conn |> authed() |> get("/v1/channels/#{@channel_id}/messages?before=does-not-exist")

    assert json_response(conn, 400)["error"]["code"] == "INVALID_CURSOR"
  end

  test "an unparseable `limit` falls back to the default page size", %{conn: conn} do
    expect(Messaging.Chat.RepoMock, :get_channel, fn @channel_id -> text_channel_doc() end)

    expect(Messaging.Chat.PermissionsClientMock, :can_send_messages?, fn _sid, _uid, _jwt ->
      {:ok, true}
    end)

    expect(Messaging.Chat.RepoMock, :list_messages, fn @channel_id, opts ->
      assert Keyword.get(opts, :limit) == 50
      {:ok, []}
    end)

    conn = conn |> authed() |> get("/v1/channels/#{@channel_id}/messages?limit=not-a-number")

    assert json_response(conn, 200)["messages"] == []
  end
end
