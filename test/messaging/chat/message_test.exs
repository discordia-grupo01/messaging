defmodule Messaging.Chat.MessageTest do
  use ExUnit.Case, async: true

  alias Messaging.Chat.Message

  describe "from_doc/1" do
    test "builds a Message from a Mongo document" do
      doc = %{
        "_id" => "msg-1",
        "channel_id" => "chan-1",
        "server_id" => "srv-1",
        "user_id" => "user-1",
        "content" => "hola",
        "inserted_at" => ~U[2026-09-28 12:00:00Z]
      }

      assert %Message{id: "msg-1", channel_id: "chan-1", content: "hola"} = Message.from_doc(doc)
    end
  end

  describe "to_api/1" do
    test "serializes with string keys and a Z-suffixed ISO 8601 timestamp" do
      message = %Message{
        id: "msg-1",
        channel_id: "chan-1",
        server_id: "srv-1",
        user_id: "user-1",
        content: "hola",
        inserted_at: ~U[2026-09-28 12:00:00.123Z]
      }

      api = Message.to_api(message)

      assert api == %{
               "id" => "msg-1",
               "channel_id" => "chan-1",
               "server_id" => "srv-1",
               "user_id" => "user-1",
               "content" => "hola",
               "inserted_at" => "2026-09-28T12:00:00.123Z"
             }

      refute String.contains?(api["inserted_at"], "+00:00")
    end

    test "round-trips through JSON with the exact same shape" do
      message = %Message{
        id: "msg-1",
        channel_id: "chan-1",
        server_id: "srv-1",
        user_id: "user-1",
        content: "hola",
        inserted_at: ~U[2026-09-28 12:00:00Z]
      }

      encoded = message |> Message.to_api() |> Jason.encode!()
      assert {:ok, decoded} = Jason.decode(encoded)
      assert decoded == Message.to_api(message)
    end
  end
end
