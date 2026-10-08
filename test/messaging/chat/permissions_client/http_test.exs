defmodule Messaging.Chat.PermissionsClient.HttpTest do
  use ExUnit.Case, async: true

  alias Messaging.Chat.PermissionsClient.Http

  setup :verify_on_exit!

  defp verify_on_exit!(context), do: Req.Test.verify_on_exit!(context)

  test "true when servers returns SEND_MESSAGES in the permissions list" do
    Req.Test.stub(Http, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer a-jwt"]

      Req.Test.json(conn, %{
        "channel_id" => "chan-1",
        "user_id" => "user-1",
        "permissions" => ["SEND_MESSAGES", "VIEW_CHANNELS"]
      })
    end)

    assert {:ok, true} = Http.can_send_messages?("chan-1", "user-1", "a-jwt")
  end

  test "asks servers for the user's effective permissions in the channel (overrides included)" do
    Req.Test.stub(Http, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1/channels/chan-1/members/user-1/permissions"
      Req.Test.json(conn, %{"permissions" => ["VIEW_CHANNELS"]})
    end)

    assert {:ok, true} = Http.can_view_channel?("chan-1", "user-1", "a-jwt")
  end

  test "false when the permissions list doesn't include SEND_MESSAGES" do
    Req.Test.stub(Http, fn conn -> Req.Test.json(conn, %{"permissions" => ["VIEW_CHANNELS"]}) end)

    assert {:ok, false} = Http.can_send_messages?("chan-1", "user-1", "a-jwt")
  end

  for status <- [401, 403, 404] do
    test "false when servers responds #{status}" do
      Req.Test.stub(Http, fn conn -> Plug.Conn.send_resp(conn, unquote(status), "") end)

      assert {:ok, false} = Http.can_send_messages?("chan-1", "user-1", "a-jwt")
    end
  end

  test "error on an unexpected status" do
    Req.Test.stub(Http, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)

    assert {:error, {:unexpected_status, 500}} =
             Http.can_send_messages?("chan-1", "user-1", "a-jwt")
  end

  test "error when the request itself fails" do
    Req.Test.stub(Http, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    assert {:error, %Req.TransportError{}} = Http.can_send_messages?("chan-1", "user-1", "a-jwt")
  end

  test "can_view_channel?/3 is true when the permissions list includes VIEW_CHANNELS" do
    Req.Test.stub(Http, fn conn -> Req.Test.json(conn, %{"permissions" => ["VIEW_CHANNELS"]}) end)

    assert {:ok, true} = Http.can_view_channel?("chan-1", "user-1", "a-jwt")
  end

  test "can_view_channel?/3 is false without VIEW_CHANNELS, even with SEND_MESSAGES" do
    Req.Test.stub(Http, fn conn -> Req.Test.json(conn, %{"permissions" => ["SEND_MESSAGES"]}) end)

    assert {:ok, false} = Http.can_view_channel?("chan-1", "user-1", "a-jwt")
  end

  test "can_manage_messages?/3 is true only when MANAGE_MESSAGES is in the permissions list" do
    Req.Test.stub(Http, fn conn ->
      Req.Test.json(conn, %{"permissions" => ["MANAGE_MESSAGES", "VIEW_CHANNELS"]})
    end)

    assert {:ok, true} = Http.can_manage_messages?("chan-1", "user-1", "a-jwt")
  end

  test "can_manage_messages?/3 is false with the default permissions" do
    Req.Test.stub(Http, fn conn ->
      Req.Test.json(conn, %{"permissions" => ["SEND_MESSAGES", "VIEW_CHANNELS"]})
    end)

    assert {:ok, false} = Http.can_manage_messages?("chan-1", "user-1", "a-jwt")
  end

  test "can_manage_messages?/3 is false for a user that is not a member (404)" do
    Req.Test.stub(Http, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)

    assert {:ok, false} = Http.can_manage_messages?("chan-1", "user-1", "a-jwt")
  end
end
