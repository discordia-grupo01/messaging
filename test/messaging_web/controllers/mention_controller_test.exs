defmodule MessagingWeb.MentionControllerTest do
  use MessagingWeb.ConnCase
  import Mox

  alias Messaging.AuthFixtures

  setup :verify_on_exit!

  @me "11111111-1111-4111-8111-111111111111"
  @author "22222222-2222-4222-8222-222222222222"
  @channel_id "chan-1"
  @server_id "srv-1"

  defp authed(conn),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> AuthFixtures.token_for(@me))

  defp mention_doc(message_id) do
    %{
      "_id" => message_id <> ":" <> @me,
      "user_id" => @me,
      "message_id" => message_id,
      "channel_id" => @channel_id,
      "server_id" => @server_id,
      "author_id" => @author,
      "inserted_at" => ~U[2026-10-06 12:00:00.000Z],
      "read_at" => nil
    }
  end

  describe "GET /v1/mentions" do
    test "requires Authorization", %{conn: conn} do
      conn = get(conn, "/v1/mentions")
      assert json_response(conn, 401)["error"]["code"] == "UNAUTHORIZED"
    end

    test "lists my unread mentions with their message", %{conn: conn} do
      expect(Messaging.Chat.RepoMock, :list_unread_mentions, fn @me, 50 ->
        {:ok, [mention_doc("msg-1")]}
      end)

      expect(Messaging.Chat.RepoMock, :get_messages, fn ["msg-1"] ->
        {:ok,
         [
           %{
             "_id" => "msg-1",
             "channel_id" => @channel_id,
             "server_id" => @server_id,
             "user_id" => @author,
             "content" => "<@#{@me}> hola",
             "inserted_at" => ~U[2026-10-06 12:00:00.000Z],
             "mentions" => [@me]
           }
         ]}
      end)

      body = conn |> authed() |> get("/v1/mentions") |> json_response(200)

      assert [
               %{
                 "id" => "msg-1:" <> @me,
                 "message_id" => "msg-1",
                 "channel_id" => @channel_id,
                 "server_id" => @server_id,
                 "author_id" => @author,
                 "inserted_at" => "2026-10-06T12:00:00.000Z",
                 "message" => %{"mentions" => [@me], "mention_everyone" => false}
               }
             ] = body["mentions"]
    end

    test "passes a valid limit and falls back to the default otherwise", %{conn: conn} do
      expect(Messaging.Chat.RepoMock, :list_unread_mentions, fn @me, 5 -> {:ok, []} end)
      expect(Messaging.Chat.RepoMock, :list_unread_mentions, fn @me, 50 -> {:ok, []} end)

      assert %{"mentions" => []} =
               conn |> authed() |> get("/v1/mentions?limit=5") |> json_response(200)

      assert %{"mentions" => []} =
               build_conn() |> authed() |> get("/v1/mentions?limit=nope") |> json_response(200)
    end

    test "a store failure is a 503, not a crash", %{conn: conn} do
      expect(Messaging.Chat.RepoMock, :list_unread_mentions, fn _, _ -> {:error, :timeout} end)

      conn = conn |> authed() |> get("/v1/mentions")
      assert json_response(conn, 503)["error"]["code"] == "MENTIONS_UNAVAILABLE"
    end
  end

  describe "POST /v1/channels/:channel_id/mentions/read" do
    test "marks my mentions of that channel as read", %{conn: conn} do
      expect(Messaging.Chat.RepoMock, :get_channel, fn @channel_id ->
        %{"_id" => @channel_id, "server_id" => @server_id, "name" => "general", "kind" => "text"}
      end)

      expect(Messaging.Chat.RepoMock, :mark_mentions_read, fn @me, @channel_id, _at -> :ok end)

      conn = conn |> authed() |> post("/v1/channels/#{@channel_id}/mentions/read")
      assert response(conn, 204) == ""
    end

    test "404 for a channel that doesn't exist", %{conn: conn} do
      expect(Messaging.Chat.RepoMock, :get_channel, fn "nope" -> nil end)

      conn = conn |> authed() |> post("/v1/channels/nope/mentions/read")
      assert json_response(conn, 404)["error"]["code"] == "CHANNEL_NOT_FOUND"
    end
  end
end
