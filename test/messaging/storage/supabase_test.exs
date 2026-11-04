defmodule Messaging.Storage.SupabaseTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Messaging.Storage.Supabase

  @secret "sb_secret_test"

  setup do
    previous_plug = Application.get_env(:messaging, :storage_http_plug)
    previous_config = Application.get_env(:messaging, :supabase_storage)

    Application.put_env(:messaging, :storage_http_plug, {Req.Test, Supabase})

    Application.put_env(:messaging, :supabase_storage,
      url: "https://ref.supabase.co/",
      secret_key: @secret,
      bucket: "adjuntos"
    )

    on_exit(fn ->
      restore(:storage_http_plug, previous_plug)
      restore(:supabase_storage, previous_config)
    end)
  end

  defp restore(key, nil), do: Application.delete_env(:messaging, key)
  defp restore(key, value), do: Application.put_env(:messaging, key, value)

  describe "put/3" do
    test "uploads the bytes with the key in apikey and never as a Bearer token" do
      Req.Test.expect(Supabase, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/storage/v1/object/adjuntos/chan-1/file-1"
        assert Plug.Conn.get_req_header(conn, "apikey") == [@secret]
        assert Plug.Conn.get_req_header(conn, "authorization") == []
        assert Plug.Conn.get_req_header(conn, "content-type") == ["application/pdf"]
        assert Plug.Conn.get_req_header(conn, "x-upsert") == ["false"]
        assert {:ok, "%PDF-bytes", conn} = Plug.Conn.read_body(conn)

        Req.Test.json(conn, %{"Key" => "adjuntos/chan-1/file-1", "Id" => "x"})
      end)

      assert {:ok, %{url: url, path: "supabase/chan-1/file-1"}} =
               Supabase.put("chan-1/file-1", "%PDF-bytes", "application/pdf")

      assert url == "https://ref.supabase.co/storage/v1/object/public/adjuntos/chan-1/file-1"
    end

    test "an unexpected status is an error that doesn't expose the key" do
      Req.Test.expect(Supabase, &Plug.Conn.send_resp(&1, 413, "too large"))

      log =
        capture_log(fn ->
          assert {:error, {:unexpected_status, 413}} =
                   Supabase.put("chan-1/file-1", "x", "application/pdf")
        end)

      assert log =~ "storage_upload_failed"
      refute log =~ @secret
    end

    test "a transport error is returned" do
      Req.Test.expect(Supabase, &Req.Test.transport_error(&1, :timeout))

      capture_log(fn ->
        assert {:error, %Req.TransportError{reason: :timeout}} =
                 Supabase.put("chan-1/file-1", "x", "application/pdf")
      end)
    end

    test "without configuration nothing is sent" do
      Application.put_env(:messaging, :supabase_storage, url: "https://ref.supabase.co")

      refute Supabase.configured?()

      assert {:error, :not_configured} = Supabase.put("chan-1/file-1", "x", "application/pdf")
    end
  end

  describe "delete/1" do
    test "removes the objects without the path prefix" do
      Req.Test.expect(Supabase, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/storage/v1/object/adjuntos"
        assert Plug.Conn.get_req_header(conn, "apikey") == [@secret]
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"prefixes" => ["chan-1/a", "chan-1/b"]}

        Req.Test.json(conn, [])
      end)

      assert :ok = Supabase.delete(["supabase/chan-1/a", "supabase/chan-1/b"])
    end

    test "a failure is returned so the cleaner retries" do
      Req.Test.expect(Supabase, &Plug.Conn.send_resp(&1, 500, "boom"))

      capture_log(fn ->
        assert {:error, {:unexpected_status, 500}} = Supabase.delete(["supabase/chan-1/a"])
      end)
    end
  end

  test "owns?/1 recognizes only its own paths" do
    assert Supabase.owns?("supabase/chan-1/a")
    refute Supabase.owns?("image/discordia/attachments/chan-1/a")
    refute Supabase.owns?("raw/discordia/attachments/chan-1/a")
  end
end
