defmodule MessagingWeb.MessageControllerTest do
  use MessagingWeb.ConnCase
  import Mox

  alias Messaging.AuthFixtures

  setup :verify_on_exit!

  setup do
    stub(Messaging.Chat.RepoMock, :get_clock, fn _key -> nil end)
    :ok
  end

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

    expect(Messaging.Chat.PermissionsClientMock, :can_view_channel?, fn @channel_id,
                                                                        ^user_id,
                                                                        _ ->
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

    conn = conn |> authed() |> get("/v1/channels/#{@channel_id}/messages?limit=2&before=msg-5")

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

  describe "PATCH /v1/channels/:channel_id/messages/:message_id" do
    @path "/v1/channels/#{@channel_id}/messages/msg-1"

    defp stored(overrides \\ %{}) do
      Map.merge(message_doc("msg-1", ~U[2026-09-28 12:00:00Z]), overrides)
      |> Map.put("user_id", "user-1")
    end

    defp allow_edit(doc \\ stored()) do
      expect(Messaging.Chat.RepoMock, :get_channel, fn @channel_id -> text_channel_doc() end)

      expect(Messaging.Chat.PermissionsClientMock, :can_send_messages?, fn @channel_id,
                                                                           "user-1",
                                                                           _jwt ->
        {:ok, true}
      end)

      expect(Messaging.Chat.RepoMock, :get_message, fn "msg-1" -> doc end)
    end

    test "requires Authorization", %{conn: conn} do
      conn = patch(conn, @path, %{"content" => "hola"})
      assert json_response(conn, 401)["error"]["code"] == "UNAUTHORIZED"
    end

    test "CA1: the author edits and gets the message back marked as edited", %{conn: conn} do
      allow_edit()

      expect(Messaging.Chat.RepoMock, :update_message, fn "msg-1",
                                                          @channel_id,
                                                          "user-1",
                                                          "corregido",
                                                          edited_at,
                                                          _mention_fields ->
        {:ok, stored(%{"content" => "corregido", "edited_at" => edited_at})}
      end)

      conn = conn |> authed() |> patch(@path, %{"content" => "  corregido "})

      assert %{
               "id" => "msg-1",
               "content" => "corregido",
               "edited" => true,
               "edited_at" => edited_at,
               "inserted_at" => "2026-09-28T12:00:00Z"
             } = json_response(conn, 200)

      assert is_binary(edited_at)
    end

    test "CA3: the edit is broadcast in real time to the channel's topic", %{conn: conn} do
      allow_edit()
      MessagingWeb.Endpoint.subscribe("channel:" <> @channel_id)

      expect(Messaging.Chat.RepoMock, :update_message, fn _id,
                                                          _cid,
                                                          _uid,
                                                          content,
                                                          edited_at,
                                                          _mention_fields ->
        {:ok, stored(%{"content" => content, "edited_at" => edited_at})}
      end)

      conn |> authed() |> patch(@path, %{"content" => "corregido"}) |> json_response(200)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "message_updated",
        payload: %{"id" => "msg-1", "content" => "corregido", "edited" => true}
      }
    end

    test "CA2: a message from someone else is 403 and nothing is broadcast", %{conn: conn} do
      allow_edit(stored(%{"user_id" => "someone-else"}) |> Map.put("user_id", "someone-else"))
      MessagingWeb.Endpoint.subscribe("channel:" <> @channel_id)

      conn = conn |> authed() |> patch(@path, %{"content" => "robado"})

      assert json_response(conn, 403)["error"]["code"] == "NOT_MESSAGE_AUTHOR"
      refute_receive %Phoenix.Socket.Broadcast{}, 100
    end

    test "an unchanged content is 200, not marked as edited, and not broadcast", %{conn: conn} do
      allow_edit()
      MessagingWeb.Endpoint.subscribe("channel:" <> @channel_id)

      conn = conn |> authed() |> patch(@path, %{"content" => "mensaje msg-1"})

      assert %{"edited" => false, "edited_at" => nil} = json_response(conn, 200)
      refute_receive %Phoenix.Socket.Broadcast{}, 100
    end

    test "400 on empty content", %{conn: conn} do
      allow_edit()
      conn = conn |> authed() |> patch(@path, %{"content" => "   "})
      assert json_response(conn, 400)["error"]["code"] == "EMPTY_CONTENT"
    end

    test "400 on content over the limit", %{conn: conn} do
      allow_edit()
      too_long = String.duplicate("a", Messaging.Chat.max_message_length() + 1)
      conn = conn |> authed() |> patch(@path, %{"content" => too_long})
      assert json_response(conn, 400)["error"]["code"] == "MESSAGE_TOO_LONG"
    end

    test "400 when content is missing or not a string", %{conn: conn} do
      for body <- [%{}, %{"content" => 123}, %{"content" => %{"a" => 1}}, %{"content" => nil}] do
        conn = conn |> authed() |> patch(@path, body)
        assert json_response(conn, 400)["error"]["code"] == "INVALID_PAYLOAD"
      end
    end

    test "403 when the caller can no longer write in the channel", %{conn: conn} do
      expect(Messaging.Chat.RepoMock, :get_channel, fn @channel_id -> text_channel_doc() end)

      expect(Messaging.Chat.PermissionsClientMock, :can_send_messages?, fn _sid, _uid, _jwt ->
        {:ok, false}
      end)

      conn = conn |> authed() |> patch(@path, %{"content" => "hola"})

      assert json_response(conn, 403)["error"]["code"] == "FORBIDDEN"
    end

    test "404 for a message that does not exist", %{conn: conn} do
      allow_edit(nil)
      conn = conn |> authed() |> patch(@path, %{"content" => "hola"})
      assert json_response(conn, 404)["error"]["code"] == "MESSAGE_NOT_FOUND"
    end

    test "404 when the message belongs to another channel", %{conn: conn} do
      allow_edit(stored(%{"channel_id" => "other-channel"}))
      conn = conn |> authed() |> patch(@path, %{"content" => "hola"})
      assert json_response(conn, 404)["error"]["code"] == "MESSAGE_NOT_FOUND"
    end

    test "404 for a channel that does not exist", %{conn: conn} do
      expect(Messaging.Chat.RepoMock, :get_channel, fn "missing" -> nil end)

      conn =
        conn |> authed() |> patch("/v1/channels/missing/messages/msg-1", %{"content" => "hola"})

      assert json_response(conn, 404)["error"]["code"] == "CHANNEL_NOT_FOUND"
    end
  end

  describe "DELETE /v1/channels/:channel_id/messages/:message_id" do
    @delete_path "/v1/channels/#{@channel_id}/messages/msg-1"

    defp allow_delete(doc, user_id \\ "user-1") do
      expect(Messaging.Chat.RepoMock, :get_channel, fn @channel_id -> text_channel_doc() end)

      expect(Messaging.Chat.PermissionsClientMock, :can_view_channel?, fn @channel_id,
                                                                          ^user_id,
                                                                          _jwt ->
        {:ok, true}
      end)

      expect(Messaging.Chat.RepoMock, :get_message, fn "msg-1" -> doc end)
    end

    defp expect_tombstone do
      expect(Messaging.Chat.RepoMock, :delete_message, fn "msg-1", @channel_id, deleted_at ->
        {:ok, Map.merge(stored(), %{"content" => "", "deleted_at" => deleted_at})}
      end)
    end

    test "requires Authorization", %{conn: conn} do
      conn = delete(conn, @delete_path)
      assert json_response(conn, 401)["error"]["code"] == "UNAUTHORIZED"
    end

    test "CA1: the author deletes their message and gets 204 with no body", %{conn: conn} do
      allow_delete(stored())
      expect_tombstone()

      conn = conn |> authed() |> delete(@delete_path)

      assert response(conn, 204) == ""
    end

    test "CA1: the deletion is broadcast in real time without the content", %{conn: conn} do
      allow_delete(stored())
      expect_tombstone()
      MessagingWeb.Endpoint.subscribe("channel:" <> @channel_id)

      conn |> authed() |> delete(@delete_path) |> response(204)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "message_deleted",
        payload: %{"id" => "msg-1", "channel_id" => @channel_id, "deleted_at" => _at} = payload
      }

      refute Map.has_key?(payload, "content")
    end

    test "CA2: a member with MANAGE_MESSAGES deletes someone else's message", %{conn: conn} do
      allow_delete(stored(), "moderator")

      expect(Messaging.Chat.PermissionsClientMock, :can_manage_messages?, fn @channel_id,
                                                                             "moderator",
                                                                             _jwt ->
        {:ok, true}
      end)

      expect_tombstone()

      conn = conn |> authed("moderator") |> delete(@delete_path)

      assert response(conn, 204) == ""
    end

    test "CA3: someone who is neither the author nor a moderator gets 403 and nothing is broadcast",
         %{conn: conn} do
      allow_delete(stored(), "intruder")

      expect(Messaging.Chat.PermissionsClientMock, :can_manage_messages?, fn _sid, _uid, _jwt ->
        {:ok, false}
      end)

      MessagingWeb.Endpoint.subscribe("channel:" <> @channel_id)

      conn = conn |> authed("intruder") |> delete(@delete_path)

      assert json_response(conn, 403)["error"]["code"] == "MESSAGE_DELETE_DENIED"
      refute_receive %Phoenix.Socket.Broadcast{}, 100
    end

    test "403 when the caller cannot view the channel", %{conn: conn} do
      expect(Messaging.Chat.RepoMock, :get_channel, fn @channel_id -> text_channel_doc() end)

      expect(Messaging.Chat.PermissionsClientMock, :can_view_channel?, fn _sid, _uid, _jwt ->
        {:ok, false}
      end)

      conn = conn |> authed() |> delete(@delete_path)

      assert json_response(conn, 403)["error"]["code"] == "FORBIDDEN"
    end

    test "404 for a message that does not exist, is in another channel, or was already deleted",
         %{conn: conn} do
      allow_delete(nil)
      conn1 = conn |> authed() |> delete(@delete_path)
      assert json_response(conn1, 404)["error"]["code"] == "MESSAGE_NOT_FOUND"

      allow_delete(stored(%{"channel_id" => "other-channel"}))
      conn2 = conn |> authed() |> delete(@delete_path)
      assert json_response(conn2, 404)["error"]["code"] == "MESSAGE_NOT_FOUND"

      allow_delete(stored(%{"content" => "", "deleted_at" => ~U[2026-09-28 12:05:00Z]}))
      conn3 = conn |> authed() |> delete(@delete_path)
      assert json_response(conn3, 404)["error"]["code"] == "MESSAGE_NOT_FOUND"
    end

    test "404 for a channel that does not exist", %{conn: conn} do
      expect(Messaging.Chat.RepoMock, :get_channel, fn "missing" -> nil end)

      conn = conn |> authed() |> delete("/v1/channels/missing/messages/msg-1")

      assert json_response(conn, 404)["error"]["code"] == "CHANNEL_NOT_FOUND"
    end
  end
end
