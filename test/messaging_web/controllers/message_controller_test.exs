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

  test "401s on a bearer token without a sub claim", %{conn: conn} do
    token = AuthFixtures.token_with_claims(%{"name" => "no-sub"})

    conn =
      conn
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
      |> get("/v1/channels/#{@channel_id}/messages")

    assert json_response(conn, 401)["error"]["code"] == "UNAUTHORIZED"
  end

  defp message_doc(id, at, channel_id \\ @channel_id),
    do: %{
      "_id" => id,
      "channel_id" => channel_id,
      "server_id" => @server_id,
      "user_id" => "user-1",
      "content" => "mensaje #{id}",
      "inserted_at" => at
    }

  defp allow_view(user_id \\ "user-1") do
    expect(Messaging.Chat.RepoMock, :get_channel, fn @channel_id -> text_channel_doc() end)

    expect(Messaging.Chat.PermissionsClientMock, :can_view_channel?, fn @server_id, ^user_id, _ ->
      {:ok, true}
    end)
  end

  test "returns the most recent messages in chronological order", %{conn: conn} do
    allow_view()

    expect(Messaging.Chat.RepoMock, :list_messages, fn @channel_id, opts ->
      assert opts[:before] == nil and opts[:after] == nil

      {:ok,
       [
         message_doc("msg-2", ~U[2026-09-28 12:00:02Z]),
         message_doc("msg-1", ~U[2026-09-28 12:00:01Z])
       ]}
    end)

    conn = conn |> authed() |> get("/v1/channels/#{@channel_id}/messages")

    assert %{"messages" => [%{"id" => "msg-1"}, %{"id" => "msg-2"}], "next_cursor" => nil} =
             json_response(conn, 200)
  end

  test "`before` returns the older page and a cursor while there is more", %{conn: conn} do
    allow_view()
    cursor_at = ~U[2026-09-28 12:00:05Z]

    expect(Messaging.Chat.RepoMock, :get_message, fn "msg-5" ->
      message_doc("msg-5", cursor_at)
    end)

    expect(Messaging.Chat.RepoMock, :list_messages, fn @channel_id, opts ->
      assert opts[:before] == {cursor_at, "msg-5"}
      assert opts[:limit] == 3
      {:ok, for(i <- [4, 3, 2], do: message_doc("msg-#{i}", ~U[2026-09-28 12:00:00Z]))}
    end)

    conn =
      conn |> authed() |> get("/v1/channels/#{@channel_id}/messages?limit=2&before=msg-5")

    assert %{"messages" => [%{"id" => "msg-3"}, %{"id" => "msg-4"}], "next_cursor" => "msg-3"} =
             json_response(conn, 200)
  end

  test "`after` returns the newer messages in chronological order", %{conn: conn} do
    allow_view()
    cursor_at = ~U[2026-09-28 12:00:01Z]

    expect(Messaging.Chat.RepoMock, :get_message, fn "msg-1" ->
      message_doc("msg-1", cursor_at)
    end)

    expect(Messaging.Chat.RepoMock, :list_messages, fn @channel_id, opts ->
      assert opts[:after] == {cursor_at, "msg-1"}

      {:ok,
       [
         message_doc("msg-2", ~U[2026-09-28 12:00:02Z]),
         message_doc("msg-3", ~U[2026-09-28 12:00:03Z])
       ]}
    end)

    conn = conn |> authed() |> get("/v1/channels/#{@channel_id}/messages?after=msg-1")

    assert %{"messages" => [%{"id" => "msg-2"}, %{"id" => "msg-3"}], "next_cursor" => nil} =
             json_response(conn, 200)
  end

  test "400s when `before` and `after` are sent together", %{conn: conn} do
    allow_view()

    conn = conn |> authed() |> get("/v1/channels/#{@channel_id}/messages?before=a&after=b")

    assert json_response(conn, 400)["error"]["code"] == "INVALID_CURSOR"
  end

  test "400s on a cursor that is not a plain id", %{conn: conn} do
    allow_view()

    conn = conn |> authed() |> get("/v1/channels/#{@channel_id}/messages?before[$ne]=x")

    assert json_response(conn, 400)["error"]["code"] == "INVALID_CURSOR"
  end

  test "400s on a cursor that belongs to another channel", %{conn: conn} do
    allow_view()

    expect(Messaging.Chat.RepoMock, :get_message, fn "msg-x" ->
      message_doc("msg-x", ~U[2026-09-28 12:00:00Z], "other-channel")
    end)

    conn = conn |> authed() |> get("/v1/channels/#{@channel_id}/messages?before=msg-x")

    assert json_response(conn, 400)["error"]["code"] == "INVALID_CURSOR"
  end

  test "403s when the caller lacks VIEW_CHANNELS", %{conn: conn} do
    expect(Messaging.Chat.RepoMock, :get_channel, fn @channel_id -> text_channel_doc() end)

    expect(Messaging.Chat.PermissionsClientMock, :can_view_channel?, fn _sid, _uid, _jwt ->
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

    expect(Messaging.Chat.PermissionsClientMock, :can_view_channel?, fn _sid, _uid, _jwt ->
      {:ok, true}
    end)

    expect(Messaging.Chat.RepoMock, :get_message, fn "does-not-exist" -> nil end)

    conn = conn |> authed() |> get("/v1/channels/#{@channel_id}/messages?before=does-not-exist")

    assert json_response(conn, 400)["error"]["code"] == "INVALID_CURSOR"
  end

  test "an unparseable `limit` falls back to the default page size", %{conn: conn} do
    expect(Messaging.Chat.RepoMock, :get_channel, fn @channel_id -> text_channel_doc() end)

    expect(Messaging.Chat.PermissionsClientMock, :can_view_channel?, fn _sid, _uid, _jwt ->
      {:ok, true}
    end)

    expect(Messaging.Chat.RepoMock, :list_messages, fn @channel_id, opts ->
      assert Keyword.get(opts, :limit) == 51
      {:ok, []}
    end)

    conn = conn |> authed() |> get("/v1/channels/#{@channel_id}/messages?limit=not-a-number")

    assert json_response(conn, 200)["messages"] == []
  end
end
