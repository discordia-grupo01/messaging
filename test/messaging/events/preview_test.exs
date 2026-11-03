defmodule Messaging.Events.PreviewTest do
  use ExUnit.Case, async: true

  alias Messaging.Chat.Message
  alias Messaging.Events.Preview

  defp message(content, attachments \\ []) do
    %Message{
      id: "01a16a21-7df1-7001-8e37-5a0fdc09d1cd",
      channel_id: "chan-1",
      server_id: "srv-1",
      user_id: "user-1",
      content: content,
      inserted_at: ~U[2026-11-03 15:00:00Z],
      attachments: attachments
    }
  end

  test "a short text goes as it is" do
    assert Preview.of(message("hola a todos")) == "hola a todos"
  end

  test "line breaks and repeated spaces become a single space" do
    assert Preview.of(message("  uno\n\n  dos   tres \n")) == "uno dos tres"
  end

  test "a user mention becomes @usuario, so no id is left in the notification" do
    assert Preview.of(message("hola <@2f6c8a10-4d6e-4b6a-9c11-0a1b2c3d4e5f> ¿venís?")) ==
             "hola @usuario ¿venís?"
  end

  test "a role mention becomes @rol" do
    role = "0a1b2c3d-0000-4000-8000-000000000000"

    assert Preview.of(message("<@&#{role}> reunión a las 5")) == "@rol reunión a las 5"
  end

  test "several mentions in the same text are all replaced" do
    assert Preview.of(message("<@a1> <@b2> y <@c3>")) == "@usuario @usuario y @usuario"
  end

  test "an @everyone stays as plain text" do
    assert Preview.of(message("@everyone atención")) == "@everyone atención"
  end

  test "a text longer than the limit is cut and marked with an ellipsis" do
    preview = Preview.of(message(String.duplicate("a", 200)))

    assert preview == String.duplicate("a", Preview.max_length()) <> "…"
    assert String.length(preview) == Preview.max_length() + 1
  end

  test "a text exactly at the limit is not cut" do
    text = String.duplicate("b", Preview.max_length())

    assert Preview.of(message(text)) == text
  end

  test "the cut never splits a character, even with accents or emoji" do
    text = String.duplicate("ñ", Preview.max_length() - 1) <> "😀😀😀"

    preview = Preview.of(message(text))

    assert String.valid?(preview)
    assert String.ends_with?(preview, "…")
  end

  test "the cut drops the trailing space instead of leaving it before the ellipsis" do
    text = String.duplicate("c", Preview.max_length() - 1) <> " resto del mensaje"

    refute Preview.of(message(text)) =~ " …"
  end

  test "a message with files and no text says so" do
    assert Preview.of(message("   ", [%{"id" => "att-1"}])) == "Archivo adjunto"
  end

  test "a message with text and files shows the text" do
    assert Preview.of(message("mirá esto", [%{"id" => "att-1"}])) == "mirá esto"
  end

  test "a message with nothing to show has no preview" do
    assert Preview.of(message("")) == nil
    assert Preview.of(message(" \n ")) == nil
  end

  test "a text that is only a mention keeps the replacement as its preview" do
    assert Preview.of(message("<@a1>")) == "@usuario"
  end
end
