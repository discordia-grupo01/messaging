defmodule MessagingWeb.VoiceAccessControllerTest do
  use MessagingWeb.ConnCase
  import Mox

  alias Messaging.AuthFixtures

  setup :verify_on_exit!

  @caller "11111111-1111-4111-8111-111111111111"
  @recipient "22222222-2222-4222-8222-222222222222"
  @conversation "33333333-3333-4333-8333-333333333333"

  defp authed(conn) do
    Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> AuthFixtures.token_for(@caller))
  end

  defp dm_doc(participants),
    do: %{
      "_id" => @conversation,
      "server_id" => nil,
      "name" => "",
      "kind" => "dm",
      "participants" => participants
    }

  defp path, do: "/v1/voice-access/#{@recipient}?conversation_id=#{@conversation}"

  test "401 UNAUTHORIZED without token", %{conn: conn} do
    conn = get(conn, path())
    assert %{"error" => %{"code" => "UNAUTHORIZED"}} = json_response(conn, 401)
  end

  test "200 allowed when the call is permitted", %{conn: conn} do
    expect(Messaging.Chat.RepoMock, :get_channel, fn @conversation ->
      dm_doc([@caller, @recipient])
    end)

    expect(Messaging.Chat.RepoMock, :get_blocks, fn _ids -> {:ok, []} end)

    conn = conn |> authed() |> get(path())
    assert json_response(conn, 200) == %{"allowed" => true}
  end

  test "403 FORBIDDEN with the envelope when the caller is not a participant", %{conn: conn} do
    expect(Messaging.Chat.RepoMock, :get_channel, fn @conversation ->
      dm_doc(["99999999-9999-4999-8999-999999999999", @recipient])
    end)

    conn = conn |> authed() |> get(path())

    assert %{"error" => %{"code" => "FORBIDDEN", "message" => message, "details" => %{}}} =
             json_response(conn, 403)

    assert message != ""
  end

  test "503 USERS_UNAVAILABLE with the envelope when users cannot be verified", %{conn: conn} do
    expect(Messaging.Chat.RepoMock, :get_channel, fn @conversation ->
      {:error, :users_unavailable}
    end)

    conn = conn |> authed() |> get(path())
    assert %{"error" => %{"code" => "USERS_UNAVAILABLE"}} = json_response(conn, 503)
  end

  test "400 INVALID_QUERY with the envelope when conversation_id is missing", %{conn: conn} do
    conn = conn |> authed() |> get("/v1/voice-access/#{@recipient}")

    assert %{
             "error" => %{
               "code" => "INVALID_QUERY",
               "message" => _message,
               "details" => _details
             }
           } = json_response(conn, 400)
  end
end
