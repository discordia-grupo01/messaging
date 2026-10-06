defmodule MessagingWeb.BlockControllerTest do
  use MessagingWeb.ConnCase
  import Mox

  alias Messaging.AuthFixtures

  setup :verify_on_exit!

  @me "11111111-1111-4111-8111-111111111111"
  @other "22222222-2222-4222-8222-222222222222"

  defp authed(conn, user_id \\ @me) do
    Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> AuthFixtures.token_for(user_id))
  end

  describe "POST /v1/blocks" do
    test "requires Authorization", %{conn: conn} do
      conn = post(conn, "/v1/blocks", %{"user_id" => @other})
      assert json_response(conn, 401)["error"]["code"] == "UNAUTHORIZED"
    end

    test "CA1: blocks an existing user and answers 204 with no body", %{conn: conn} do
      expect(Messaging.Chat.UsersClientMock, :user_exists?, fn @other, _jwt -> {:ok, true} end)

      expect(Messaging.Chat.RepoMock, :put_block, fn doc ->
        assert doc["blocker_id"] == @me and doc["blocked_id"] == @other
        :ok
      end)

      conn = conn |> authed() |> post("/v1/blocks", %{"user_id" => @other})

      assert response(conn, 204) == ""
    end

    test "blocking someone already blocked is also 204", %{conn: conn} do
      stub(Messaging.Chat.UsersClientMock, :user_exists?, fn _id, _jwt -> {:ok, true} end)
      stub(Messaging.Chat.RepoMock, :put_block, fn _doc -> :ok end)

      assert conn |> authed() |> post("/v1/blocks", %{"user_id" => @other}) |> response(204)
      assert conn |> authed() |> post("/v1/blocks", %{"user_id" => @other}) |> response(204)
    end

    test "400 when blocking yourself", %{conn: conn} do
      conn = conn |> authed() |> post("/v1/blocks", %{"user_id" => @me})

      assert json_response(conn, 400)["error"]["code"] == "CANNOT_BLOCK_SELF"
    end

    test "404 for a user that does not exist, or an id that is not valid", %{conn: conn} do
      expect(Messaging.Chat.UsersClientMock, :user_exists?, fn _id, _jwt -> {:ok, false} end)

      conn1 = conn |> authed() |> post("/v1/blocks", %{"user_id" => @other})
      assert json_response(conn1, 404)["error"]["code"] == "USER_NOT_FOUND"

      conn2 = conn |> authed() |> post("/v1/blocks", %{"user_id" => "a.b"})
      assert json_response(conn2, 404)["error"]["code"] == "USER_NOT_FOUND"
    end

    test "503 when identify-service cannot confirm the user", %{conn: conn} do
      expect(Messaging.Chat.UsersClientMock, :user_exists?, fn _id, _jwt -> {:error, :timeout} end)

      conn = conn |> authed() |> post("/v1/blocks", %{"user_id" => @other})

      assert json_response(conn, 503)["error"]["code"] == "USERS_UNAVAILABLE"
    end
  end

  describe "POST /v1/blocks with a bad body" do
    test "400 when user_id is missing or is not a string, and nothing is stored", %{conn: conn} do
      for body <- [
            %{},
            %{"user_id" => 5},
            %{"user_id" => nil},
            %{"user_id" => %{"$ne" => "x"}},
            %{"id" => @other}
          ] do
        conn = conn |> authed() |> post("/v1/blocks", body)
        assert json_response(conn, 400)["error"]["code"] == "INVALID_PAYLOAD"
      end
    end
  end

  describe "DELETE /v1/blocks/:user_id" do
    test "requires Authorization", %{conn: conn} do
      conn = delete(conn, "/v1/blocks/#{@other}")
      assert json_response(conn, 401)["error"]["code"] == "UNAUTHORIZED"
    end

    test "CA3: unblocks and answers 204", %{conn: conn} do
      expect(Messaging.Chat.RepoMock, :delete_block, fn id ->
        assert id == @me <> ":" <> @other
        :ok
      end)

      conn = conn |> authed() |> delete("/v1/blocks/#{@other}")

      assert response(conn, 204) == ""
    end

    test "unblocking someone who was not blocked is also 204", %{conn: conn} do
      expect(Messaging.Chat.RepoMock, :delete_block, fn _id -> :ok end)

      assert conn |> authed() |> delete("/v1/blocks/#{@other}") |> response(204)
    end

    test "400 when unblocking yourself and 404 for an invalid id", %{conn: conn} do
      conn1 = conn |> authed() |> delete("/v1/blocks/#{@me}")
      assert json_response(conn1, 400)["error"]["code"] == "CANNOT_BLOCK_SELF"

      conn2 = conn |> authed() |> delete("/v1/blocks/a.b")
      assert json_response(conn2, 404)["error"]["code"] == "USER_NOT_FOUND"
    end
  end

  describe "GET /v1/blocks" do
    test "requires Authorization", %{conn: conn} do
      conn = get(conn, "/v1/blocks")
      assert json_response(conn, 401)["error"]["code"] == "UNAUTHORIZED"
    end

    test "lists only who I blocked, with nothing else", %{conn: conn} do
      at = ~U[2026-10-06 12:00:00.000Z]

      expect(Messaging.Chat.RepoMock, :list_blocks, fn @me, 50 ->
        {:ok, [%{"_id" => "x", "blocker_id" => @me, "blocked_id" => @other, "created_at" => at}]}
      end)

      conn = conn |> authed() |> get("/v1/blocks")

      assert %{"blocks" => [block]} = json_response(conn, 200)
      assert block == %{"user_id" => @other, "created_at" => "2026-10-06T12:00:00.000Z"}
    end

    test "an empty list, and the limit is passed on", %{conn: conn} do
      expect(Messaging.Chat.RepoMock, :list_blocks, fn _id, 10 -> {:ok, []} end)

      assert conn |> authed() |> get("/v1/blocks?limit=10") |> json_response(200) == %{
               "blocks" => []
             }

      expect(Messaging.Chat.RepoMock, :list_blocks, fn _id, 50 -> {:ok, []} end)

      Phoenix.ConnTest.build_conn()
      |> authed()
      |> get("/v1/blocks?limit=abc")
      |> json_response(200)
    end
  end
end
