defmodule Messaging.Storage.TieredTest do
  use ExUnit.Case, async: false

  alias Messaging.Chat.Attachment
  alias Messaging.Storage.Tiered

  setup do
    previous =
      for key <- [:storage_http_plug, :cloudinary, :supabase_storage],
          do: {key, Application.get_env(:messaging, key)}

    Application.put_env(:messaging, :storage_http_plug, {Req.Test, __MODULE__})
    Application.put_env(:messaging, :cloudinary, url: "cloudinary://key:secret@democloud")

    Application.put_env(:messaging, :supabase_storage,
      url: "https://ref.supabase.co",
      secret_key: "sb_secret_test"
    )

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:messaging, key)
        {key, value} -> Application.put_env(:messaging, key, value)
      end)
    end)
  end

  defp cloudinary_upload_response(conn) do
    Req.Test.json(conn, %{
      "secure_url" => "https://res.cloudinary.com/x",
      "public_id" => "discordia/attachments/chan-1/a",
      "resource_type" => "raw"
    })
  end

  describe "put/3" do
    test "a file of exactly the free limit stays in Cloudinary" do
      assert Tiered.storage_for(Attachment.max_bytes()) == Messaging.Storage.Cloudinary
      assert Tiered.storage_for(Attachment.max_bytes() + 1) == Messaging.Storage.Supabase
    end

    test "a small file goes to Cloudinary" do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.host == "api.cloudinary.com"
        cloudinary_upload_response(conn)
      end)

      assert {:ok, %{path: "raw/discordia/attachments/chan-1/a"}} =
               Tiered.put("chan-1/a", "%PDF-bytes", "application/pdf")
    end

    test "one byte more goes to Supabase" do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.host == "ref.supabase.co"
        Req.Test.json(conn, %{"Key" => "attachments/chan-1/a"})
      end)

      body = :binary.copy(<<0>>, Attachment.max_bytes() + 1)

      assert {:ok, %{path: "supabase/chan-1/a"}} =
               Tiered.put("chan-1/a", body, "application/pdf")
    end
  end

  describe "delete/1" do
    test "each path is deleted where it lives" do
      test_pid = self()

      Req.Test.expect(__MODULE__, 2, fn conn ->
        send(test_pid, {:deleted_from, conn.host})
        Req.Test.json(conn, %{})
      end)

      assert :ok = Tiered.delete(["raw/discordia/attachments/c/a", "supabase/c/b"])

      assert_received {:deleted_from, "api.cloudinary.com"}
      assert_received {:deleted_from, "ref.supabase.co"}
    end

    test "only Cloudinary is called when no path is in Supabase" do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.host == "api.cloudinary.com"
        Req.Test.json(conn, %{})
      end)

      assert :ok = Tiered.delete(["image/discordia/attachments/c/a"])
    end

    test "a Cloudinary failure is returned so the cleaner retries" do
      Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 500, "boom"))

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:unexpected_status, 500}} =
                 Tiered.delete(["image/discordia/attachments/c/a", "supabase/c/b"])
      end)
    end
  end
end
