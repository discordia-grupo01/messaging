defmodule Messaging.Chat.PermissionsClient.HttpTest do
  use ExUnit.Case, async: true

  alias Messaging.Chat.PermissionsClient.Http

  setup :verify_on_exit!

  defp verify_on_exit!(context), do: Req.Test.verify_on_exit!(context)

  test "true when servers returns SEND_MESSAGES in the permissions list" do
    Req.Test.stub(Http, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer a-jwt"]

      Req.Test.json(conn, %{
        "server_id" => "srv-1",
        "user_id" => "user-1",
        "permissions" => ["SEND_MESSAGES", "VIEW_CHANNELS"]
      })
    end)

    assert {:ok, true} = Http.can_send_messages?("srv-1", "user-1", "a-jwt")
  end

  test "false when the permissions list doesn't include SEND_MESSAGES" do
    Req.Test.stub(Http, fn conn -> Req.Test.json(conn, %{"permissions" => ["VIEW_CHANNELS"]}) end)

    assert {:ok, false} = Http.can_send_messages?("srv-1", "user-1", "a-jwt")
  end

  for status <- [401, 403, 404] do
    test "false when servers responds #{status}" do
      Req.Test.stub(Http, fn conn -> Plug.Conn.send_resp(conn, unquote(status), "") end)

      assert {:ok, false} = Http.can_send_messages?("srv-1", "user-1", "a-jwt")
    end
  end

  test "error on an unexpected status" do
    Req.Test.stub(Http, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)

    assert {:error, {:unexpected_status, 500}} =
             Http.can_send_messages?("srv-1", "user-1", "a-jwt")
  end

  test "error when the request itself fails" do
    Req.Test.stub(Http, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    assert {:error, %Req.TransportError{}} = Http.can_send_messages?("srv-1", "user-1", "a-jwt")
  end
end
