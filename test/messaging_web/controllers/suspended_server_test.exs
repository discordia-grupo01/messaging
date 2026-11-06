defmodule MessagingWeb.SuspendedServerTest do
  @moduledoc """
  A server suspended by the platform staff answers `403 SERVER_SUSPENDED` on every
  REST route that reads or writes one of its channels. Nothing is read or written:
  the mocks have no expectation beyond the channel lookup.
  """
  use MessagingWeb.ConnCase
  import Mox

  alias Messaging.AuthFixtures
  alias Messaging.SuspensionHelper

  setup :verify_on_exit!

  @server_id "srv-1"
  @other_server "srv-2"
  @channel_id "chan-1"
  @other_channel "chan-2"
  @user "user-1"

  setup do
    stub(Messaging.Chat.RepoMock, :get_clock, fn _key -> nil end)

    stub(Messaging.Chat.RepoMock, :get_channel, fn
      @channel_id -> channel_doc(@channel_id, @server_id)
      @other_channel -> channel_doc(@other_channel, @other_server)
      _other -> nil
    end)

    stub(Messaging.Chat.PermissionsStoreMock, :can_view_channel?, fn _channel, _user ->
      {:ok, true}
    end)

    SuspensionHelper.stub_server_suspended(@server_id)
    :ok
  end

  defp channel_doc(id, server_id),
    do: %{"_id" => id, "server_id" => server_id, "name" => id, "kind" => "text"}

  defp authed(conn) do
    Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> AuthFixtures.token_for(@user))
  end

  defp assert_server_suspended(conn) do
    assert %{"error" => %{"code" => "SERVER_SUSPENDED", "message" => message}} =
             json_response(conn, 403)

    assert message =~ "suspendido"
  end

  test "reading the history is refused", %{conn: conn} do
    conn = conn |> authed() |> get("/v1/channels/#{@channel_id}/messages")

    assert_server_suspended(conn)
  end

  test "editing a message is refused", %{conn: conn} do
    conn =
      conn
      |> authed()
      |> patch("/v1/channels/#{@channel_id}/messages/msg-1", %{"content" => "nuevo"})

    assert_server_suspended(conn)
  end

  test "deleting a message is refused", %{conn: conn} do
    conn = conn |> authed() |> delete("/v1/channels/#{@channel_id}/messages/msg-1")

    assert_server_suspended(conn)
  end

  test "searching the server is refused", %{conn: conn} do
    conn = conn |> authed() |> get("/v1/servers/#{@server_id}/messages/search?q=hola")

    assert_server_suspended(conn)
  end

  test "marking the mentions of one of its channels as read is refused", %{conn: conn} do
    conn = conn |> authed() |> post("/v1/channels/#{@channel_id}/mentions/read")

    assert_server_suspended(conn)
  end

  test "an upload to one of its channels is refused", %{conn: conn} do
    stub(Messaging.Chat.RepoMock, :premium?, fn _user -> false end)

    conn =
      conn
      |> authed()
      |> Plug.Conn.put_req_header("content-type", "image/png")
      |> post("/v1/attachments?channel_id=#{@channel_id}&filename=foto.png", "png-bytes")

    assert_server_suspended(conn)
  end

  test "a message of a suspended server is left out of the lookup, the rest is returned",
       %{conn: conn} do
    at = ~U[2026-09-28 12:00:00Z]

    doc = fn id, channel_id, server_id ->
      %{
        "_id" => id,
        "channel_id" => channel_id,
        "server_id" => server_id,
        "user_id" => "user-1",
        "content" => "mensaje #{id}",
        "inserted_at" => at
      }
    end

    expect(Messaging.Chat.RepoMock, :get_messages, fn ["msg-1", "msg-2"] ->
      {:ok,
       [doc.("msg-1", @channel_id, @server_id), doc.("msg-2", @other_channel, @other_server)]}
    end)

    conn = conn |> authed() |> get("/v1/messages?ids=msg-1,msg-2")

    assert %{"messages" => [%{"id" => "msg-2"}]} = json_response(conn, 200)
  end

  test "another server keeps working", %{conn: conn} do
    expect(Messaging.Chat.RepoMock, :list_messages, fn @other_channel, _opts -> {:ok, []} end)
    stub(Messaging.Chat.RepoMock, :list_reactions, fn _ids -> {:ok, []} end)

    conn = conn |> authed() |> get("/v1/channels/#{@other_channel}/messages")

    assert %{"messages" => []} = json_response(conn, 200)
  end

  test "reactivating it opens the channels again", %{conn: conn} do
    SuspensionHelper.stub_active()
    expect(Messaging.Chat.RepoMock, :list_messages, fn @channel_id, _opts -> {:ok, []} end)
    stub(Messaging.Chat.RepoMock, :list_reactions, fn _ids -> {:ok, []} end)

    conn = conn |> authed() |> get("/v1/channels/#{@channel_id}/messages")

    assert %{"messages" => []} = json_response(conn, 200)
  end

  test "an account that is also suspended is told so first", %{conn: conn} do
    SuspensionHelper.stub_suspended(@user)

    conn = conn |> authed() |> get("/v1/channels/#{@channel_id}/messages")

    assert %{"error" => %{"code" => "ACCOUNT_SUSPENDED"}} = json_response(conn, 403)
  end

  test "if the state of the server cannot be read the request fails closed with 503",
       %{conn: conn} do
    SuspensionHelper.stub_server_suspension_check_failing()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        conn = conn |> authed() |> get("/v1/channels/#{@channel_id}/messages")

        assert %{"error" => %{"code" => "SUSPENSION_UNAVAILABLE"}} = json_response(conn, 503)
      end)

    assert log =~ "server_suspension_check_failed"
  end
end
