defmodule MessagingWeb.PresenceControllerTest do
  use MessagingWeb.ConnCase
  import ExUnit.CaptureLog
  import Mox

  alias Messaging.AuthFixtures

  setup :verify_on_exit!

  @me "11111111-1111-4111-8111-111111111111"
  @beto "22222222-2222-4222-8222-222222222222"
  @cami "33333333-3333-4333-8333-333333333333"

  defp authed(conn) do
    Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> AuthFixtures.token_for(@me))
  end

  defp doc(user_id, manual, idle, version),
    do: %{
      "_id" => user_id,
      "manual" => manual,
      "connections" => [%{"id" => "c", "instance" => "i", "idle" => idle}],
      "version" => version
    }

  test "requires Authorization", %{conn: conn} do
    conn = get(conn, "/v1/presence?user_ids=" <> @beto)
    assert json_response(conn, 401)["error"]["code"] == "UNAUTHORIZED"
  end

  test "CA1-CA4: returns the status of each user asked for, in order", %{conn: conn} do
    expect(Messaging.Presence.StoreMock, :get_many, fn [@beto, @cami, @me] ->
      {:ok, [doc(@beto, "online", true, 5), doc(@me, "invisible", false, 2)]}
    end)

    stub(Messaging.Chat.RepoMock, :get_blocks, fn _ids -> {:ok, []} end)

    conn = conn |> authed() |> get("/v1/presence?user_ids=#{@beto},#{@cami},#{@me}")

    assert json_response(conn, 200) == %{
             "presences" => [
               %{"user_id" => @beto, "status" => "idle", "version" => 5},
               %{"user_id" => @cami, "status" => "offline", "version" => 0},
               %{"user_id" => @me, "status" => "offline", "version" => 2}
             ]
           }
  end

  test "someone with a block with me shows offline", %{conn: conn} do
    stub(Messaging.Presence.StoreMock, :get_many, fn _ids ->
      {:ok, [doc(@beto, "online", false, 3)]}
    end)

    stub(Messaging.Chat.RepoMock, :get_blocks, fn _ids ->
      {:ok, [%{"_id" => @beto <> ":" <> @me, "blocker_id" => @beto, "blocked_id" => @me}]}
    end)

    conn = conn |> authed() |> get("/v1/presence?user_ids=" <> @beto)

    assert [%{"status" => "offline"}] = json_response(conn, 200)["presences"]
  end

  test "repeated ids and spaces are tolerated", %{conn: conn} do
    expect(Messaging.Presence.StoreMock, :get_many, fn [@beto] -> {:ok, []} end)

    conn = conn |> authed() |> get("/v1/presence?user_ids=#{@beto},%20#{@beto},")

    assert [%{"user_id" => @beto}] = json_response(conn, 200)["presences"]
  end

  test "400 without ids, with an invalid id or with more than 100", %{conn: conn} do
    too_many = Enum.map_join(1..101, ",", &"user-#{&1}")

    for query <- ["", "?user_ids=", "?user_ids=a.b", "?user_ids=$ne", "?user_ids=" <> too_many] do
      conn = conn |> authed() |> get("/v1/presence" <> query)
      assert json_response(conn, 400)["error"]["code"] == "INVALID_PAYLOAD"
    end
  end

  test "503 if the presence cannot be read", %{conn: conn} do
    stub(Messaging.Presence.StoreMock, :get_many, fn _ids -> {:error, :timeout} end)

    log =
      capture_log(fn ->
        conn = conn |> authed() |> get("/v1/presence?user_ids=" <> @beto)
        assert json_response(conn, 503)["error"]["code"] == "PRESENCE_UNAVAILABLE"
      end)

    assert log =~ "presence_snapshot_failed"
  end
end
