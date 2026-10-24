defmodule MessagingWeb.SearchControllerTest do
  use MessagingWeb.ConnCase
  import Mox

  alias Messaging.AuthFixtures
  alias Messaging.ReplicaFixtures, as: Fixtures

  setup :verify_on_exit!

  @path "/v1/servers/srv-1/messages/search"
  @at ~U[2026-10-24 12:00:00.000Z]

  setup do
    stub(Messaging.Chat.RepoMock, :get_member, fn
      "srv-1", "ana" -> Fixtures.member("ana", ["everyone"])
      "srv-1", _user -> nil
    end)

    stub(Messaging.Chat.RepoMock, :get_server_owner, fn "srv-1" -> "owner-1" end)
    stub(Messaging.Chat.RepoMock, :list_roles, fn "srv-1" -> {:ok, Fixtures.roles()} end)
    stub(Messaging.Chat.RepoMock, :list_text_channel_ids, fn "srv-1" -> {:ok, ["general"]} end)
    stub(Messaging.Chat.RepoMock, :list_channel_overrides, fn _ids -> {:ok, %{}} end)
    :ok
  end

  defp authed(conn, user_id \\ "ana") do
    Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> AuthFixtures.token_for(user_id))
  end

  defp doc(id) do
    %{
      "_id" => id,
      "channel_id" => "general",
      "server_id" => "srv-1",
      "user_id" => "ana",
      "content" => "hice el deploy",
      "inserted_at" => @at
    }
  end

  test "requires Authorization", %{conn: conn} do
    conn = get(conn, @path, q: "deploy")
    assert json_response(conn, 401)["error"]["code"] == "UNAUTHORIZED"
  end

  test "returns the matches, newest first, with the total of the first page", %{conn: conn} do
    expect(Messaging.Chat.RepoMock, :search_messages, fn ["general"], opts ->
      assert opts[:text] == "deploy"
      assert opts[:author_id] == "ana"
      {:ok, [doc("m2"), doc("m1")]}
    end)

    expect(Messaging.Chat.RepoMock, :count_search_matches, fn _ids, _opts, _cap -> {:ok, 2} end)

    conn = conn |> authed() |> get(@path, q: "deploy", author_id: "ana")
    body = json_response(conn, 200)

    assert Enum.map(body["messages"], & &1["id"]) == ["m2", "m1"]
    assert hd(body["messages"])["content"] == "hice el deploy"
    assert body["next_cursor"] == nil
    assert body["total"] == 2
    assert body["total_capped"] == false
  end

  test "no matches is a 200 with an empty list", %{conn: conn} do
    expect(Messaging.Chat.RepoMock, :search_messages, fn _ids, _opts -> {:ok, []} end)
    expect(Messaging.Chat.RepoMock, :count_search_matches, fn _ids, _opts, _cap -> {:ok, 0} end)

    conn = conn |> authed() |> get(@path, q: "nada")

    assert %{"messages" => [], "next_cursor" => nil, "total" => 0} = json_response(conn, 200)
  end

  test "a page after the first one carries no total", %{conn: conn} do
    stub(Messaging.Chat.RepoMock, :get_message, fn "m2" -> doc("m2") end)
    expect(Messaging.Chat.RepoMock, :search_messages, fn _ids, _opts -> {:ok, [doc("m1")]} end)

    conn = conn |> authed() |> get(@path, q: "deploy", before: "m2", limit: "10")

    assert %{"total" => nil, "total_capped" => nil} = json_response(conn, 200)
  end

  test "400 INVALID_SEARCH_QUERY without a text or an author", %{conn: conn} do
    conn = conn |> authed() |> get(@path)
    assert json_response(conn, 400)["error"]["code"] == "INVALID_SEARCH_QUERY"
  end

  test "400 INVALID_CURSOR for a cursor that is not from this server", %{conn: conn} do
    stub(Messaging.Chat.RepoMock, :get_message, fn _id -> nil end)

    conn = conn |> authed() |> get(@path, q: "deploy", before: "nope")
    assert json_response(conn, 400)["error"]["code"] == "INVALID_CURSOR"
  end

  test "403 NOT_SERVER_MEMBER for someone outside the server", %{conn: conn} do
    conn = conn |> authed("stranger") |> get(@path, q: "deploy")
    assert json_response(conn, 403)["error"]["code"] == "NOT_SERVER_MEMBER"
  end

  test "404 for a channel_id that is not a text channel of the server", %{conn: conn} do
    conn = conn |> authed() |> get(@path, q: "deploy", channel_id: "voice-1")
    assert json_response(conn, 404)["error"]["code"] == "CHANNEL_NOT_FOUND"
  end

  test "503 SEARCH_UNAVAILABLE when Mongo fails", %{conn: conn} do
    expect(Messaging.Chat.RepoMock, :search_messages, fn _ids, _opts -> {:error, :timeout} end)

    conn = conn |> authed() |> get(@path, q: "deploy")
    assert json_response(conn, 503)["error"]["code"] == "SEARCH_UNAVAILABLE"
  end
end
