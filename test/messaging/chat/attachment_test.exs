defmodule Messaging.Chat.AttachmentTest do
  use ExUnit.Case, async: true

  alias Messaging.Chat.Attachment
  alias Messaging.FileFixtures

  describe "validate/1 accepts only JPEG, PNG, WebP and PDF" do
    test "recognises each format by its content" do
      assert {:ok, %{content_type: "image/jpeg", extension: "jpg"}} =
               Attachment.validate(FileFixtures.jpeg())

      assert {:ok, %{content_type: "image/png", extension: "png"}} =
               Attachment.validate(FileFixtures.png())

      assert {:ok, %{content_type: "image/webp", extension: "webp"}} =
               Attachment.validate(FileFixtures.webp())

      assert {:ok, %{content_type: "application/pdf", extension: "pdf"}} =
               Attachment.validate(FileFixtures.pdf())
    end

    test "CA2: other formats are rejected, whatever their name says" do
      for content <- [
            "GIF89a" <> :binary.copy(<<0>>, 20),
            "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>",
            "MZ" <> :binary.copy(<<0>>, 20),
            "#!/bin/sh\nrm -rf /\n",
            "PK" <> <<3, 4>> <> :binary.copy(<<0>>, 20),
            "texto plano"
          ] do
        assert {:error, :unsupported_file_type} = Attachment.validate(content)
      end
    end

    test "a RIFF file that is not WebP is rejected" do
      assert {:error, :unsupported_file_type} =
               Attachment.validate("RIFF" <> <<0, 0, 0, 0>> <> "WAVE" <> <<0, 0>>)
    end

    test "an empty file is rejected on its own" do
      assert {:error, :empty_file} = Attachment.validate(<<>>)
    end
  end

  describe "validate/1 limits the size to 10 MB" do
    test "CA1: a file of exactly 10 MB is accepted" do
      assert {:ok, _detected} = Attachment.validate(FileFixtures.sized(:png, 10 * 1024 * 1024))
    end

    test "CA3: one byte more is rejected, even if the format is fine" do
      assert {:error, :file_too_large} =
               Attachment.validate(FileFixtures.sized(:pdf, 10 * 1024 * 1024 + 1))
    end

    test "a file that is too large and also not allowed is reported as too large" do
      assert {:error, :file_too_large} =
               Attachment.validate(:binary.copy("a", 10 * 1024 * 1024 + 1))
    end
  end

  describe "sanitize_name/2" do
    test "keeps a normal name" do
      assert Attachment.sanitize_name("foto vacaciones.png", "png") == "foto vacaciones.png"
    end

    test "drops any directory part, from either kind of path" do
      assert Attachment.sanitize_name("../../etc/passwd", "png") == "passwd"
      assert Attachment.sanitize_name("C:\\Users\\ana\\cv.pdf", "pdf") == "cv.pdf"
    end

    test "removes control characters and trims" do
      assert Attachment.sanitize_name("  a\u0000b\nc.pdf ", "pdf") == "abc.pdf"
    end

    test "cuts very long names" do
      name = String.duplicate("a", 500) <> ".png"
      assert String.length(Attachment.sanitize_name(name, "png")) == 100
    end

    test "falls back to a generic name when there is none" do
      for empty <- [nil, "", "   ", "/", "\u0000"] do
        assert Attachment.sanitize_name(empty, "webp") == "archivo.webp"
      end
    end
  end

  test "the storage path does not depend on the name the client chose" do
    assert Attachment.object_key("chan-1", "att-1") == "chan-1/att-1"
  end

  test "embed/1 keeps only what the clients need" do
    doc = %{
      "_id" => "att-1",
      "url" => "https://x/att-1.png",
      "name" => "a.png",
      "content_type" => "image/png",
      "size" => 10,
      "user_id" => "u",
      "path" => "p",
      "channel_id" => "c"
    }

    assert Attachment.embed(doc) == %{
             "id" => "att-1",
             "url" => "https://x/att-1.png",
             "name" => "a.png",
             "content_type" => "image/png",
             "size" => 10
           }
  end
end
