defmodule Messaging.Chat.MentionsClient.HttpTest do
  use ExUnit.Case, async: false

  alias Messaging.Chat.{Mentions, MentionsClient}
  alias Messaging.Chat.MentionsClient.Http

  setup :verify_on_exit!

  defp verify_on_exit!(context), do: Req.Test.verify_on_exit!(context)

  @query %{user_ids: ["ana"], role_ids: ["role-1"], everyone: true}

  test "asks servers with the author's token and the mentions found" do
    Req.Test.stub(Http, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/servers/srv-1/mentions/resolve"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer a-jwt"]
      assert ["application/json" <> _] = Plug.Conn.get_req_header(conn, "content-type")

      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(body) == %{
               "channel_id" => "chan-1",
               "user_ids" => ["ana"],
               "role_ids" => ["role-1"],
               "everyone" => true
             }

      Req.Test.json(conn, %{
        "user_ids" => ["ana"],
        "role_ids" => ["role-1"],
        "everyone" => true,
        "recipient_ids" => ["ana", "bob"]
      })
    end)

    assert {:ok,
            %Mentions{
              user_ids: ["ana"],
              role_ids: ["role-1"],
              everyone: true,
              recipient_ids: ["ana", "bob"]
            }} = Http.resolve("srv-1", "chan-1", @query, "a-jwt")
  end

  test "CA4 comes back as data, not as an error: no roles and no @everyone" do
    Req.Test.stub(Http, fn conn ->
      Req.Test.json(conn, %{
        "user_ids" => ["ana"],
        "role_ids" => [],
        "everyone" => false,
        "recipient_ids" => ["ana"]
      })
    end)

    assert {:ok, %Mentions{role_ids: [], everyone: false, recipient_ids: ["ana"]}} =
             Http.resolve("srv-1", "chan-1", @query, "a-jwt")
  end

  for status <- [400, 403, 404, 500] do
    test "error when servers responds #{status}" do
      Req.Test.stub(Http, fn conn -> Plug.Conn.send_resp(conn, unquote(status), "") end)

      assert {:error, {:unexpected_status, unquote(status)}} =
               Http.resolve("srv-1", "chan-1", @query, "a-jwt")
    end
  end

  test "error when the body doesn't have the expected shape" do
    Req.Test.stub(Http, fn conn -> Req.Test.json(conn, %{"recipient_ids" => "nope"}) end)

    assert {:error, :invalid_body} = Http.resolve("srv-1", "chan-1", @query, "a-jwt")
  end

  test "error when the request itself fails" do
    Req.Test.stub(Http, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    assert {:error, %Req.TransportError{}} = Http.resolve("srv-1", "chan-1", @query, "a-jwt")
  end

  describe "MentionsClient.resolve/4" do
    setup do
      previous = Application.get_env(:messaging, :mentions_client)
      Application.put_env(:messaging, :mentions_client, Http)
      on_exit(fn -> Application.put_env(:messaging, :mentions_client, previous) end)
    end

    test "any failure becomes :mentions_unavailable" do
      Req.Test.stub(Http, fn conn -> Plug.Conn.send_resp(conn, 503, "") end)

      assert {:error, :mentions_unavailable} =
               MentionsClient.resolve("srv-1", "chan-1", @query, "a-jwt")
    end
  end
end
