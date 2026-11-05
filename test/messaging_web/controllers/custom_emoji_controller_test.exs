defmodule MessagingWeb.CustomEmojiControllerTest do
  use MessagingWeb.ConnCase
  import ExUnit.CaptureLog
  import Mox

  alias Messaging.AuthFixtures

  setup :verify_on_exit!

  @me "11111111-1111-4111-8111-111111111111"
  @id "2f4e6a8c-1b3d-4f5a-9c7e-8d6b4a2c0e1f"

  defp authed(conn),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> AuthFixtures.token_for(@me))

  test "requires Authorization", %{conn: conn} do
    assert json_response(get(conn, "/v1/custom-emojis?ids=#{@id}"), 401)
  end

  test "returns the emojis, deleted ones included", %{conn: conn} do
    expect(Messaging.Chat.RepoMock, :get_custom_emojis, fn [@id] ->
      {:ok,
       [
         %{
           "_id" => @id,
           "server_id" => "srv",
           "name" => "party",
           "animated" => true,
           "image_url" => "https://cdn.test/party.gif",
           "deleted" => true
         }
       ]}
    end)

    conn = conn |> authed() |> get("/v1/custom-emojis?ids=#{@id},nope")

    assert %{
             "emojis" => [
               %{
                 "id" => @id,
                 "name" => "party",
                 "animated" => true,
                 "image_url" => "https://cdn.test/party.gif",
                 "deleted" => true
               }
             ]
           } = json_response(conn, 200)
  end

  test "without ids returns an empty list", %{conn: conn} do
    expect(Messaging.Chat.RepoMock, :get_custom_emojis, fn [] -> {:ok, []} end)

    assert %{"emojis" => []} = conn |> authed() |> get("/v1/custom-emojis") |> json_response(200)
  end

  test "more ids than allowed is a 400", %{conn: conn} do
    ids = List.duplicate(@id, 101) |> Enum.join(",")
    conn = conn |> authed() |> get("/v1/custom-emojis?ids=#{ids}")

    assert json_response(conn, 400)["error"]["code"] == "TOO_MANY_CUSTOM_EMOJIS"
  end

  test "a read failure is a 503", %{conn: conn} do
    expect(Messaging.Chat.RepoMock, :get_custom_emojis, fn _ids -> {:error, :down} end)

    capture_log(fn ->
      conn = conn |> authed() |> get("/v1/custom-emojis?ids=#{@id}")
      assert json_response(conn, 503)["error"]["code"] == "CUSTOM_EMOJIS_UNAVAILABLE"
    end)
  end
end
