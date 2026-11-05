defmodule MessagingWeb.AttachmentControllerTest do
  use MessagingWeb.ConnCase
  import Mox

  alias Messaging.Auth.TicketStoreMock
  alias Messaging.AuthFixtures
  alias Messaging.Chat.Conversation
  alias Messaging.FileFixtures
  alias Messaging.SuspensionHelper

  setup :verify_on_exit!

  setup do
    stub(Messaging.Chat.RepoMock, :get_clock, fn _key -> nil end)
    stub(Messaging.Chat.RepoMock, :premium?, fn _user -> false end)
    stub(Messaging.Chat.RepoMock, :server_boost_level, fn _server_id -> 0 end)
    :ok
  end

  @me "11111111-1111-4111-8111-111111111111"
  @other "22222222-2222-4222-8222-222222222222"
  @channel_id "chan-1"

  defp authed(conn, user_id \\ @me) do
    Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> AuthFixtures.token_for(user_id))
  end

  defp upload(conn, query, body, content_type \\ "application/octet-stream") do
    conn
    |> authed()
    |> Plug.Conn.put_req_header("content-type", content_type)
    |> post("/v1/attachments?" <> query, body)
  end

  defp allow_channel do
    stub(Messaging.Chat.RepoMock, :get_channel, fn @channel_id ->
      %{"_id" => @channel_id, "server_id" => "srv-1", "name" => "general", "kind" => "text"}
    end)

    stub(Messaging.Chat.PermissionsStoreMock, :can_send_messages?, fn _channel, @me ->
      {:ok, true}
    end)
  end

  defp allow_storage do
    stub(Messaging.Chat.RepoMock, :count_pending_attachments, fn _user -> {:ok, 0} end)

    stub(Messaging.StorageMock, :put, fn key, _body, _type ->
      {:ok, %{url: "https://cdn.test/" <> key, path: "image/" <> key}}
    end)

    stub(Messaging.Chat.RepoMock, :insert_attachment, fn _doc -> :ok end)
  end

  test "requires Authorization", %{conn: conn} do
    conn =
      conn
      |> Plug.Conn.put_req_header("content-type", "image/png")
      |> post("/v1/attachments?channel_id=#{@channel_id}", FileFixtures.png())

    assert json_response(conn, 401)["error"]["code"] == "UNAUTHORIZED"
  end

  describe "CA1: a successful upload" do
    for {kind, type} <- [
          jpeg: "image/jpeg",
          png: "image/png",
          webp: "image/webp",
          pdf: "application/pdf"
        ] do
      test "accepts #{kind} and answers with the public URL", %{conn: conn} do
        allow_channel()
        allow_storage()
        kind = unquote(kind)
        type = unquote(type)

        conn =
          upload(
            conn,
            "channel_id=#{@channel_id}&filename=archivo",
            apply(FileFixtures, kind, [])
          )

        assert %{
                 "id" => id,
                 "url" => url,
                 "name" => "archivo",
                 "content_type" => ^type,
                 "size" => size
               } = json_response(conn, 201)

        assert is_binary(id)
        assert url =~ "https://cdn.test/#{@channel_id}/#{id}"
        assert size == byte_size(apply(FileFixtures, kind, []))
      end
    end

    test "the declared Content-Type is not trusted: the content decides", %{conn: conn} do
      allow_channel()
      allow_storage()

      conn = upload(conn, "channel_id=#{@channel_id}", FileFixtures.png(), "application/pdf")

      assert %{"content_type" => "image/png", "name" => name} = json_response(conn, 201)
      assert name == "archivo.png"
    end

    test "a direct message upload goes to the conversation of that pair", %{conn: conn} do
      allow_storage()
      stub(Messaging.Chat.RepoMock, :get_blocks, fn _ids -> {:ok, []} end)
      stub(Messaging.Chat.RepoMock, :user_known?, fn @other -> true end)
      conversation = Conversation.id(@me, @other)

      expect(Messaging.Chat.RepoMock, :insert_attachment, fn doc ->
        assert doc["channel_id"] == conversation
        :ok
      end)

      conn = upload(conn, "to=#{@other}", FileFixtures.pdf())

      assert %{"content_type" => "application/pdf"} = json_response(conn, 201)
    end
  end

  describe "CA2: a format that is not allowed" do
    test "is rejected with a descriptive error and nothing is stored", %{conn: conn} do
      allow_channel()

      conn = upload(conn, "channel_id=#{@channel_id}&filename=virus.exe", "MZ" <> <<0, 0, 0>>)

      assert %{"error" => %{"code" => "UNSUPPORTED_FILE_TYPE", "message" => message}} =
               json_response(conn, 415)

      assert message =~ "JPEG, PNG o WebP"
      assert message =~ "PDF"
    end

    test "a GIF named .png is rejected too", %{conn: conn} do
      allow_channel()

      conn =
        upload(
          conn,
          "channel_id=#{@channel_id}&filename=a.png",
          "GIF89a" <> <<0, 0>>,
          "image/png"
        )

      assert json_response(conn, 415)["error"]["code"] == "UNSUPPORTED_FILE_TYPE"
    end

    test "an empty body is its own error", %{conn: conn} do
      allow_channel()

      conn = upload(conn, "channel_id=#{@channel_id}", "")

      assert json_response(conn, 400)["error"]["code"] == "EMPTY_FILE"
    end
  end

  describe "CA3: a file that is too large" do
    test "is rejected with a descriptive error and the limit in it", %{conn: conn} do
      allow_channel()
      big = FileFixtures.sized(:png, 10 * 1024 * 1024 + 1)

      conn = upload(conn, "channel_id=#{@channel_id}", big)

      assert %{"error" => %{"code" => "FILE_TOO_LARGE", "message" => message}} =
               json_response(conn, 413)

      assert message =~ "10 MB"
    end

    test "a file of exactly 10 MB is accepted", %{conn: conn} do
      allow_channel()
      allow_storage()

      conn = upload(conn, "channel_id=#{@channel_id}", FileFixtures.sized(:pdf, 10 * 1024 * 1024))

      assert %{"size" => 10_485_760} = json_response(conn, 201)
    end

    test "the declared length rejects the upload before the body is read", %{conn: conn} do
      allow_channel()

      conn =
        conn
        |> authed()
        |> Plug.Conn.put_req_header("content-type", "application/octet-stream")
        |> Plug.Conn.put_req_header("content-length", "99999999999")
        |> post("/v1/attachments?channel_id=#{@channel_id}", "x")

      assert json_response(conn, 413)["error"]["code"] == "FILE_TOO_LARGE"
    end
  end

  describe "a direct upload with a ticket" do
    defp direct(conn, query, body) do
      conn
      |> Plug.Conn.put_req_header("content-type", "application/octet-stream")
      |> post("/v1/attachments/direct?" <> query, body)
    end

    defp with_ticket(conn), do: Plug.Conn.put_req_header(conn, "x-upload-ticket", "a-ticket")

    defp stub_ticket(doc), do: expect(TicketStoreMock, :take, fn _id -> {:ok, doc} end)

    test "uploads as the user of the ticket", %{conn: conn} do
      stub_ticket(AuthFixtures.ticket_doc(@me))
      allow_channel()
      allow_storage()

      conn = conn |> with_ticket() |> direct("channel_id=#{@channel_id}", FileFixtures.png())

      assert %{"content_type" => "image/png"} = json_response(conn, 201)
    end

    test "applies the same size limit as the upload with a token", %{conn: conn} do
      stub_ticket(AuthFixtures.ticket_doc(@me))
      allow_channel()

      conn =
        conn
        |> with_ticket()
        |> Plug.Conn.put_req_header("content-length", "99999999999")
        |> direct("channel_id=#{@channel_id}", "x")

      assert json_response(conn, 413)["error"]["code"] == "FILE_TOO_LARGE"
    end

    test "applies the same permissions as the upload with a token", %{conn: conn} do
      stub_ticket(AuthFixtures.ticket_doc("33333333-3333-4333-8333-333333333333"))

      stub(Messaging.Chat.RepoMock, :get_channel, fn @channel_id ->
        %{"_id" => @channel_id, "server_id" => "srv-1", "name" => "general", "kind" => "text"}
      end)

      stub(Messaging.Chat.PermissionsStoreMock, :can_send_messages?, fn _channel, _user ->
        {:ok, false}
      end)

      conn = conn |> with_ticket() |> direct("channel_id=#{@channel_id}", FileFixtures.png())

      assert json_response(conn, 403)["error"]["code"] == "FORBIDDEN"
    end

    test "requires a ticket: a valid token is not enough", %{conn: conn} do
      conn = conn |> authed() |> direct("channel_id=#{@channel_id}", FileFixtures.png())

      assert json_response(conn, 401)["error"]["code"] == "UNAUTHORIZED"
    end

    test "rejects an unknown or already used ticket", %{conn: conn} do
      stub_ticket(nil)

      conn = conn |> with_ticket() |> direct("channel_id=#{@channel_id}", FileFixtures.png())

      assert json_response(conn, 401)["error"]["code"] == "UNAUTHORIZED"
    end

    test "rejects an expired ticket", %{conn: conn} do
      stub_ticket(AuthFixtures.ticket_doc(@me, ttl: -1))

      conn = conn |> with_ticket() |> direct("channel_id=#{@channel_id}", FileFixtures.png())

      assert json_response(conn, 401)["error"]["code"] == "UNAUTHORIZED"
    end

    test "rejects a ticket of a user suspended after it was issued", %{conn: conn} do
      stub_ticket(AuthFixtures.ticket_doc(@me))
      SuspensionHelper.stub_suspended(@me)

      conn = conn |> with_ticket() |> direct("channel_id=#{@channel_id}", FileFixtures.png())

      assert json_response(conn, 403)["error"]["code"] == "ACCOUNT_SUSPENDED"
    end
  end

  describe "the limit of a boosted server" do
    setup do
      stub(Messaging.Chat.RepoMock, :server_boost_level, fn "srv-1" -> 2 end)
      stub(Messaging.Chat.RepoMock, :count_pending_attachments, fn @me -> {:ok, 0} end)
      stub(Messaging.Chat.RepoMock, :insert_attachment, fn _doc -> :ok end)

      stub(Messaging.StorageMock, :put, fn key, _body, _type ->
        {:ok, %{url: "https://cdn.test/" <> key, path: "supabase/" <> key}}
      end)

      allow_channel()
      :ok
    end

    test "a member uploads 25 MB in a level 2 server", %{conn: conn} do
      body = FileFixtures.sized(:pdf, 25 * 1024 * 1024)
      conn = upload(conn, "channel_id=#{@channel_id}&filename=a.pdf", body)
      assert %{"size" => 26_214_400} = json_response(conn, 201)
    end

    test "over 25 MB is too large", %{conn: conn} do
      body = FileFixtures.sized(:pdf, 25 * 1024 * 1024 + 1)
      conn = upload(conn, "channel_id=#{@channel_id}&filename=a.pdf", body)
      assert json_response(conn, 413)["error"]["code"] == "FILE_TOO_LARGE"
    end
  end

  describe "the limit of a Premium user" do
    setup do
      stub(Messaging.Chat.RepoMock, :premium?, fn @me -> true end)
      allow_channel()
      :ok
    end

    test "a file of exactly 50 MB is accepted", %{conn: conn} do
      allow_storage()

      conn = upload(conn, "channel_id=#{@channel_id}", FileFixtures.sized(:pdf, 50 * 1024 * 1024))

      assert %{"size" => 52_428_800} = json_response(conn, 201)
    end

    test "one byte more is rejected", %{conn: conn} do
      conn =
        upload(conn, "channel_id=#{@channel_id}", FileFixtures.sized(:pdf, 50 * 1024 * 1024 + 1))

      assert %{"error" => %{"code" => "FILE_TOO_LARGE", "message" => message}} =
               json_response(conn, 413)

      assert message =~ "50 MB"
    end

    test "a GIF is accepted", %{conn: conn} do
      allow_storage()

      conn = upload(conn, "channel_id=#{@channel_id}&filename=risa.gif", FileFixtures.gif())

      assert %{"content_type" => "image/gif", "name" => "risa.gif"} = json_response(conn, 201)
    end
  end

  test "a GIF from a free user is rejected without touching storage", %{conn: conn} do
    allow_channel()
    expect(Messaging.StorageMock, :put, 0, fn _key, _body, _type -> {:error, :unused} end)

    conn = upload(conn, "channel_id=#{@channel_id}", FileFixtures.gif())

    assert %{"error" => %{"code" => "UNSUPPORTED_FILE_TYPE", "message" => message}} =
             json_response(conn, 415)

    assert message =~ "GIF con Premium"
  end

  test "when Premium can't be read the free limit applies", %{conn: conn} do
    stub(Messaging.Chat.RepoMock, :premium?, fn _user -> {:error, :mongo_down} end)
    allow_channel()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        conn = upload(conn, "channel_id=#{@channel_id}", FileFixtures.sized(:pdf, 10_485_761))
        assert json_response(conn, 413)["error"]["code"] == "FILE_TOO_LARGE"
      end)

    assert log =~ "premium_lookup_failed"
  end

  describe "permissions and destination" do
    test "needs exactly one destination", %{conn: conn} do
      for query <- ["", "channel_id=&filename=a", "channel_id=#{@channel_id}&to=#{@other}"] do
        conn = upload(conn, query, FileFixtures.png())
        assert json_response(conn, 400)["error"]["code"] == "INVALID_PAYLOAD"
      end
    end

    test "403 without permission to write in the channel", %{conn: conn} do
      stub(Messaging.Chat.RepoMock, :get_channel, fn _ ->
        %{"_id" => @channel_id, "server_id" => "srv-1", "name" => "general", "kind" => "text"}
      end)

      stub(Messaging.Chat.PermissionsStoreMock, :can_send_messages?, fn _c, _u -> {:ok, false} end)

      conn = upload(conn, "channel_id=#{@channel_id}", FileFixtures.png())

      assert json_response(conn, 403)["error"]["code"] == "FORBIDDEN"
    end

    test "403 when a direct message is blocked", %{conn: conn} do
      stub(Messaging.Chat.RepoMock, :get_blocks, fn _ids ->
        {:ok, [%{"_id" => @me <> ":" <> @other}]}
      end)

      conn = upload(conn, "to=#{@other}", FileFixtures.png())

      assert json_response(conn, 403)["error"]["code"] == "USER_BLOCKED"
    end

    test "404 for a channel that does not exist", %{conn: conn} do
      stub(Messaging.Chat.RepoMock, :get_channel, fn _ -> nil end)

      conn = upload(conn, "channel_id=ghost", FileFixtures.png())

      assert json_response(conn, 404)["error"]["code"] == "CHANNEL_NOT_FOUND"
    end

    test "the body is not even read when the user may not write there", %{conn: conn} do
      stub(Messaging.Chat.RepoMock, :get_channel, fn _ -> nil end)

      conn = upload(conn, "channel_id=ghost", FileFixtures.sized(:png, 1_000_000))

      assert json_response(conn, 404)
    end
  end

  describe "storage problems" do
    test "429 when the user has too many files waiting", %{conn: conn} do
      allow_channel()
      stub(Messaging.Chat.RepoMock, :count_pending_attachments, fn _ -> {:ok, 20} end)

      conn = upload(conn, "channel_id=#{@channel_id}", FileFixtures.png())

      assert json_response(conn, 429)["error"]["code"] == "TOO_MANY_PENDING_ATTACHMENTS"
    end

    test "503 when the file could not be stored", %{conn: conn} do
      allow_channel()
      stub(Messaging.Chat.RepoMock, :count_pending_attachments, fn _ -> {:ok, 0} end)
      stub(Messaging.StorageMock, :put, fn _p, _b, _c -> {:error, :not_configured} end)

      conn = upload(conn, "channel_id=#{@channel_id}", FileFixtures.png())

      assert json_response(conn, 503)["error"]["code"] == "STORAGE_UNAVAILABLE"
    end
  end
end
