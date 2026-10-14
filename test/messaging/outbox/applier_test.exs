defmodule Messaging.Outbox.ApplierTest do
  use ExUnit.Case, async: true
  import Mox

  alias Messaging.Outbox.Applier

  setup :verify_on_exit!

  test "there is nothing to apply for a notification" do
    assert :ok = Applier.apply(nil)
  end

  test "an insert is an upsert in Mongo, with the dates back as dates" do
    expect(Messaging.Chat.RepoMock, :upsert_message, fn doc ->
      assert doc["_id"] == "msg-1"
      assert doc["content"] == "hola"
      assert doc["inserted_at"] == ~U[2026-10-13 12:00:00.123Z]
      :ok
    end)

    assert :ok =
             Applier.apply(%{
               "op" => "insert_message",
               "doc" => %{
                 "_id" => "msg-1",
                 "content" => "hola",
                 "inserted_at" => "2026-10-13T12:00:00.123Z"
               }
             })
  end

  test "an update carries the fields to set, with their dates" do
    expect(Messaging.Chat.RepoMock, :apply_message_update, fn "msg-1", "chan-1", fields ->
      assert fields == %{
               "content" => "nuevo",
               "edited_at" => ~U[2026-10-13 12:05:00.000Z],
               "changed_at" => ~U[2026-10-13 12:05:00.000Z]
             }

      :ok
    end)

    assert :ok =
             Applier.apply(%{
               "op" => "update_message",
               "id" => "msg-1",
               "channel_id" => "chan-1",
               "fields" => %{
                 "content" => "nuevo",
                 "edited_at" => "2026-10-13T12:05:00.000Z",
                 "changed_at" => "2026-10-13T12:05:00.000Z"
               }
             })
  end

  test "a delete is a soft delete, and deleting what is already deleted is fine" do
    expect(Messaging.Chat.RepoMock, :delete_message, fn "msg-1", "chan-1", at ->
      assert at == ~U[2026-10-13 12:10:00.000Z]
      {:ok, nil}
    end)

    assert :ok =
             Applier.apply(%{
               "op" => "delete_message",
               "id" => "msg-1",
               "channel_id" => "chan-1",
               "deleted_at" => "2026-10-13T12:10:00.000Z"
             })
  end

  test "a failure writing to Mongo is returned so the poller tries again" do
    expect(Messaging.Chat.RepoMock, :upsert_message, fn _doc -> {:error, :timeout} end)

    assert {:error, :timeout} =
             Applier.apply(%{"op" => "insert_message", "doc" => %{"_id" => "msg-1"}})
  end

  test "an instruction it does not know is an invalid row, never a retry" do
    assert {:error, {:invalid, {:unknown_apply, "teleport"}}} =
             Applier.apply(%{"op" => "teleport"})
  end

  test "encode_dates/1 turns the dates of a document into ISO 8601 and leaves the rest alone" do
    doc = %{"_id" => "m", "inserted_at" => ~U[2026-10-13 12:00:00.123Z], "mentions" => ["a"]}

    assert Applier.encode_dates(doc) == %{
             "_id" => "m",
             "inserted_at" => "2026-10-13T12:00:00.123Z",
             "mentions" => ["a"]
           }
  end
end
