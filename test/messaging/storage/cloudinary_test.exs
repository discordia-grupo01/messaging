defmodule Messaging.Storage.CloudinaryTest do
  use ExUnit.Case, async: false

  alias Messaging.Storage.Cloudinary

  @secret "s3cr3t-api-secret"

  setup do
    previous_plug = Application.get_env(:messaging, :storage_http_plug)
    previous_config = Application.get_env(:messaging, :cloudinary)

    Application.put_env(:messaging, :storage_http_plug, {Req.Test, Cloudinary})

    Application.put_env(:messaging, :cloudinary,
      url: "cloudinary://12345:#{@secret}@democloud",
      folder: "/discordia/attachments/",
      api_base: "https://api.cloudinary.com/"
    )

    on_exit(fn ->
      restore(:storage_http_plug, previous_plug)
      restore(:cloudinary, previous_config)
    end)
  end

  defp restore(key, nil), do: Application.delete_env(:messaging, key)
  defp restore(key, value), do: Application.put_env(:messaging, key, value)

  defp parse(conn, parsers) do
    opts = Plug.Parsers.init(parsers: parsers, pass: ["*/*"])
    Plug.Parsers.call(conn, opts)
  end

  defp expected_signature(params) do
    to_sign =
      params
      |> Enum.sort()
      |> Enum.map_join("&", fn {name, value} -> "#{name}=#{value}" end)

    :sha |> :crypto.hash(to_sign <> @secret) |> Base.encode16(case: :lower)
  end

  describe "put/3" do
    test "uploads the bytes signed with the secret, which is never sent" do
      Req.Test.expect(Cloudinary, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1_1/democloud/auto/upload"
        conn = parse(conn, [:multipart])
        params = conn.body_params

        assert %Plug.Upload{content_type: "image/png"} = params["file"]
        assert File.read!(params["file"].path) == "bytes"
        assert params["api_key"] == "12345"
        assert params["public_id"] == "discordia/attachments/chan-1/att-1"
        assert params["overwrite"] == "false"
        assert params["unique_filename"] == "false"
        assert String.to_integer(params["timestamp"]) |> abs() > 1_000_000_000

        signed = Map.take(params, ["overwrite", "public_id", "timestamp", "unique_filename"])
        assert params["signature"] == expected_signature(signed)
        refute Enum.any?(Map.values(params), &(&1 == @secret))
        refute conn.query_string =~ @secret

        Req.Test.json(conn, %{
          "secure_url" =>
            "https://res.cloudinary.com/democloud/image/upload/v1/discordia/attachments/chan-1/att-1.png",
          "public_id" => "discordia/attachments/chan-1/att-1",
          "resource_type" => "image"
        })
      end)

      assert {:ok,
              %{
                url:
                  "https://res.cloudinary.com/democloud/image/upload/v1/discordia/attachments/chan-1/att-1.png",
                path: "image/discordia/attachments/chan-1/att-1"
              }} = Cloudinary.put("chan-1/att-1", "bytes", "image/png")
    end

    test "a PDF that Cloudinary stores as another resource type keeps that type in its path" do
      Req.Test.expect(Cloudinary, fn conn ->
        Req.Test.json(conn, %{
          "secure_url" => "https://res.cloudinary.com/democloud/raw/upload/v1/x/a.pdf",
          "public_id" => "x/a.pdf",
          "resource_type" => "raw"
        })
      end)

      assert {:ok, %{path: "raw/x/a.pdf"}} = Cloudinary.put("a", "%PDF-1.4", "application/pdf")
    end

    test "a refusal from Cloudinary is an error, not a URL" do
      Req.Test.expect(Cloudinary, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => %{"message" => "Invalid Signature"}})
      end)

      assert {:error, {:unexpected_status, 401}} = Cloudinary.put("a", "x", "image/png")
    end

    test "an answer without the URL is an error" do
      Req.Test.expect(Cloudinary, fn conn -> Req.Test.json(conn, %{"ok" => true}) end)

      assert {:error, :invalid_response} = Cloudinary.put("a", "x", "image/png")
    end

    test "a network failure is an error" do
      Req.Test.expect(Cloudinary, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, _reason} = Cloudinary.put("a", "x", "image/png")
    end
  end

  describe "delete/1" do
    test "removes the files of each resource type with the credentials in basic auth" do
      test_pid = self()

      Req.Test.stub(Cloudinary, fn conn ->
        conn = parse(conn, [:urlencoded])
        send(test_pid, {:delete, conn.request_path, conn.body_params["public_ids"], conn})
        Req.Test.json(conn, %{"deleted" => %{}, "partial" => false})
      end)

      assert :ok = Cloudinary.delete(["image/d/a", "image/d/b", "raw/d/c.pdf"])

      assert_received {:delete, "/v1_1/democloud/resources/image/upload", ["d/a", "d/b"], conn}

      assert Plug.Conn.get_req_header(conn, "authorization") == [
               "Basic " <> Base.encode64("12345:" <> @secret)
             ]

      assert conn.method == "DELETE"
      assert_received {:delete, "/v1_1/democloud/resources/raw/upload", ["d/c.pdf"], _conn}
    end

    test "splits long lists into batches of 100" do
      test_pid = self()

      Req.Test.stub(Cloudinary, fn conn ->
        conn = parse(conn, [:urlencoded])
        send(test_pid, {:batch, length(conn.body_params["public_ids"])})
        Req.Test.json(conn, %{"deleted" => %{}})
      end)

      assert :ok = Cloudinary.delete(for n <- 1..250, do: "image/d/#{n}")

      assert_received {:batch, 100}
      assert_received {:batch, 100}
      assert_received {:batch, 50}
    end

    test "stops at the first failure and reports it" do
      Req.Test.expect(Cloudinary, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
      end)

      assert {:error, {:unexpected_status, 500}} = Cloudinary.delete(["image/d/a"])
    end

    test "a path without a resource type is taken as an image" do
      test_pid = self()

      Req.Test.stub(Cloudinary, fn conn ->
        send(test_pid, {:path, conn.request_path})
        Req.Test.json(conn, %{"deleted" => %{}})
      end)

      assert :ok = Cloudinary.delete(["solo"])
      assert_received {:path, "/v1_1/democloud/resources/image/upload"}
    end
  end

  describe "configuration" do
    test "without CLOUDINARY_URL nothing is sent" do
      Application.put_env(:messaging, :cloudinary, url: nil)

      refute Cloudinary.configured?()
      assert {:error, :not_configured} = Cloudinary.put("a", "x", "image/png")
      assert {:error, :not_configured} = Cloudinary.delete(["image/a"])
    end

    test "configured?/0 needs cloud name, key and secret in a cloudinary:// URL" do
      assert Cloudinary.configured?()

      for bad <- [
            "",
            "https://12345:secret@democloud",
            "cloudinary://democloud",
            "cloudinary://:secret@democloud",
            "cloudinary://12345:@democloud",
            "cloudinary://12345:secret@"
          ] do
        Application.put_env(:messaging, :cloudinary, url: bad)
        refute Cloudinary.configured?(), "#{bad} should not be valid"
      end
    end

    test "the default folder and API host are used when none are given" do
      Application.put_env(:messaging, :cloudinary, url: "cloudinary://12345:#{@secret}@democloud")

      Req.Test.expect(Cloudinary, fn conn ->
        conn = parse(conn, [:multipart])
        assert conn.body_params["public_id"] == "discordia/attachments/k"
        assert conn.host == "api.cloudinary.com"

        Req.Test.json(conn, %{
          "secure_url" => "https://res.cloudinary.com/x",
          "public_id" => "p",
          "resource_type" => "image"
        })
      end)

      assert {:ok, _} = Cloudinary.put("k", "x", "image/png")
    end
  end
end
