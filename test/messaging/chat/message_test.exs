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

  describe "edited messages" do
    @doc_base %{
      "_id" => "msg-1",
      "channel_id" => "chan-1",
      "server_id" => "srv-1",
      "user_id" => "user-1",
      "content" => "hola",
      "inserted_at" => ~U[2026-09-28 12:00:00Z]
    }

    test "a document written before editing existed reads as not edited" do
      message = Message.from_doc(@doc_base)

      assert message.edited_at == nil
      assert %{"edited" => false, "edited_at" => nil} = Message.to_api(message)
    end

    test "a document with edited_at reads as edited and exposes the timestamp" do
      doc = Map.put(@doc_base, "edited_at", ~U[2026-09-28 12:05:00.250Z])
      message = Message.from_doc(doc)

      assert message.edited_at == ~U[2026-09-28 12:05:00.250Z]

      assert %{"edited" => true, "edited_at" => "2026-09-28T12:05:00.250Z"} =
               Message.to_api(message)
    end

    test "an explicit nil edited_at is not edited" do
      doc = Map.put(@doc_base, "edited_at", nil)

      assert %{"edited" => false, "edited_at" => nil} =
               doc |> Message.from_doc() |> Message.to_api()
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
               "inserted_at" => "2026-09-28T12:00:00.123Z",
               "edited" => false,
               "edited_at" => nil
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

  describe "direct messages" do
    test "to_api/1 exposes a null server_id" do
      doc = %{
        "_id" => "msg-1",
        "channel_id" => "dm-1",
        "server_id" => nil,
        "user_id" => "user-1",
        "content" => "hola",
        "inserted_at" => ~U[2026-09-28 12:00:00Z]
      }

      assert %{"server_id" => nil, "channel_id" => "dm-1"} =
               doc |> Message.from_doc() |> Message.to_api()
    end
  end
end
