defmodule MessagingWeb.ConversationControllerTest do
  use MessagingWeb.ConnCase
  import Mox

  alias Messaging.AuthFixtures

  setup :verify_on_exit!

  @me "11111111-1111-4111-8111-111111111111"
  @other "22222222-2222-4222-8222-222222222222"

  defp authed(conn, user_id \\ @me) do
    Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> AuthFixtures.token_for(user_id))
  end

  defp conversation_doc(id, partner, overrides \\ %{}) do
    Map.merge(
      %{
        "_id" => id,
        "kind" => "dm",
        "participants" => Enum.sort([@me, partner]),
        "last_message_id" => "m-" <> id,
        "last_message_user_id" => partner,
        "last_message_at" => ~U[2026-10-05 12:00:00Z]
      },
      overrides
    )
  end

  defp message_doc(id, channel_id, content) do
    %{
      "_id" => id,
      "channel_id" => channel_id,
      "server_id" => nil,
      "user_id" => @other,
      "content" => content,
      "inserted_at" => ~U[2026-10-05 12:00:00Z]
    }
  end

  describe "GET /v1/conversations" do
    setup do
      stub(Messaging.Chat.RepoMock, :get_blocks, fn _ids -> {:ok, []} end)
      :ok
    end

    test "requires Authorization", %{conn: conn} do
      conn = get(conn, "/v1/conversations")
      assert json_response(conn, 401)["error"]["code"] == "UNAUTHORIZED"
    end

    test "lists my conversations with the partner, the unread flag and the last message",
         %{conn: conn} do
      expect(Messaging.Chat.RepoMock, :list_conversations, fn @me, 50 ->
        {:ok,
         [
           conversation_doc("dm-1", @other),
           conversation_doc("dm-2", "33333333-3333-4333-8333-333333333333", %{
             "last_message_user_id" => @me,
             "last_message_id" => "m-dm-2"
           })
         ]}
      end)

      expect(Messaging.Chat.RepoMock, :get_messages, fn ids ->
        assert Enum.sort(ids) == ["m-dm-1", "m-dm-2"]
        {:ok, [message_doc("m-dm-1", "dm-1", "hola"), message_doc("m-dm-2", "dm-2", "chau")]}
      end)

      conn = conn |> authed() |> get("/v1/conversations")

      assert %{"conversations" => [first, second]} = json_response(conn, 200)

      assert %{
               "id" => "dm-1",
               "partner_id" => @other,
               "unread" => true,
               "blocked_by_me" => false,
               "last_message_at" => "2026-10-05T12:00:00Z",
               "last_message" => %{"content" => "hola", "server_id" => nil}
             } = first

      assert %{"id" => "dm-2", "unread" => false} = second
    end

    test "blocked_by_me is true only for the partners I blocked", %{conn: conn} do
      expect(Messaging.Chat.RepoMock, :list_conversations, fn _uid, _limit ->
        {:ok,
         [
           conversation_doc("dm-1", @other),
           conversation_doc("dm-2", "33333333-3333-4333-8333-333333333333")
         ]}
      end)

      expect(Messaging.Chat.RepoMock, :get_messages, fn _ids -> {:ok, []} end)

      expect(Messaging.Chat.RepoMock, :get_blocks, fn _ids ->
        {:ok, [%{"_id" => @me <> ":" <> @other, "blocked_id" => @other}]}
      end)

      conn = conn |> authed() |> get("/v1/conversations")

      assert %{"conversations" => [first, second]} = json_response(conn, 200)
      assert %{"id" => "dm-1", "blocked_by_me" => true} = first
      assert %{"id" => "dm-2", "blocked_by_me" => false} = second
      refute Map.has_key?(first, "blocks_me")
    end

    test "an empty list when there is nothing", %{conn: conn} do
      expect(Messaging.Chat.RepoMock, :list_conversations, fn _uid, _limit -> {:ok, []} end)

      conn = conn |> authed() |> get("/v1/conversations")

      assert json_response(conn, 200) == %{"conversations" => []}
    end

    test "limit is passed on, and an unparseable one falls back to the default", %{conn: conn} do
      expect(Messaging.Chat.RepoMock, :list_conversations, fn _uid, 10 -> {:ok, []} end)
      conn |> authed() |> get("/v1/conversations?limit=10") |> json_response(200)

      expect(Messaging.Chat.RepoMock, :list_conversations, fn _uid, 50 -> {:ok, []} end)
      conn |> authed() |> get("/v1/conversations?limit=abc") |> json_response(200)
    end

    test "the last message of a conversation can be null once it was deleted", %{conn: conn} do
      expect(Messaging.Chat.RepoMock, :list_conversations, fn _uid, _limit ->
        {:ok, [conversation_doc("dm-1", @other)]}
      end)

      expect(Messaging.Chat.RepoMock, :get_messages, fn _ids -> {:ok, []} end)

      conn = conn |> authed() |> get("/v1/conversations")

      assert %{"conversations" => [%{"last_message" => nil, "unread" => true}]} =
               json_response(conn, 200)
    end
  end

  describe "POST /v1/conversations/:id/read" do
    test "requires Authorization", %{conn: conn} do
      conn = post(conn, "/v1/conversations/dm-1/read")
      assert json_response(conn, 401)["error"]["code"] == "UNAUTHORIZED"
    end

    test "marks the conversation as read and answers 204", %{conn: conn} do
      at = ~U[2026-10-05 12:00:00Z]

      expect(Messaging.Chat.RepoMock, :get_channel, fn "dm-1" ->
        conversation_doc("dm-1", @other)
      end)

      expect(Messaging.Chat.RepoMock, :mark_read, fn "dm-1", @me, ^at -> :ok end)

      conn = conn |> authed() |> post("/v1/conversations/dm-1/read")

      assert response(conn, 204) == ""
    end

    test "404 for a conversation of two other people, same as for one that does not exist",
         %{conn: conn} do
      expect(Messaging.Chat.RepoMock, :get_channel, fn _id ->
        conversation_doc("dm-1", @other, %{"participants" => ["a", "b"]})
      end)

      conn1 = conn |> authed() |> post("/v1/conversations/dm-1/read")
      assert json_response(conn1, 404)["error"]["code"] == "CHANNEL_NOT_FOUND"

      expect(Messaging.Chat.RepoMock, :get_channel, fn _id -> nil end)
      conn2 = conn |> authed() |> post("/v1/conversations/ghost/read")
      assert json_response(conn2, 404)["error"]["code"] == "CHANNEL_NOT_FOUND"
    end
  end
end
