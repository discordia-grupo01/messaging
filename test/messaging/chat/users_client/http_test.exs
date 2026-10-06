defmodule Messaging.Chat.UsersClient.HttpTest do
  use ExUnit.Case, async: true

  alias Messaging.Chat.UsersClient.Http

  setup :verify_on_exit!

  defp verify_on_exit!(context), do: Req.Test.verify_on_exit!(context)

  @user_id "11111111-1111-4111-8111-111111111111"

  test "true when identify-service finds the user, asking with the caller's JWT" do
    Req.Test.stub(Http, fn conn ->
      assert conn.request_path == "/v1/users/" <> @user_id
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer a-jwt"]
      Req.Test.json(conn, %{"id" => @user_id, "name" => "Ana"})
    end)

    assert {:ok, true} = Http.user_exists?(@user_id, "a-jwt")
  end

  for status <- [400, 404] do
    test "false when identify-service answers #{status}" do
      Req.Test.stub(Http, fn conn -> Plug.Conn.send_resp(conn, unquote(status), "") end)

      assert {:ok, false} = Http.user_exists?(@user_id, "a-jwt")
    end
  end

  test "an error on any other status, never a guess" do
    for status <- [401, 500, 503] do
      Req.Test.stub(Http, fn conn -> Plug.Conn.send_resp(conn, status, "") end)

      assert {:error, {:unexpected_status, ^status}} = Http.user_exists?(@user_id, "a-jwt")
    end
  end

  test "error when the request itself fails, without retrying for long" do
    Req.Test.stub(Http, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    {micros, result} = :timer.tc(fn -> Http.user_exists?(@user_id, "a-jwt") end)

    assert {:error, %Req.TransportError{}} = result
    assert micros < 1_000_000
  end

  test "the id is encoded so it cannot change the path" do
    Req.Test.stub(Http, fn conn ->
      assert conn.request_path == "/v1/users/..%2Fme"
      Plug.Conn.send_resp(conn, 404, "")
    end)

    assert {:ok, false} = Http.user_exists?("../me", "a-jwt")
  end
end
