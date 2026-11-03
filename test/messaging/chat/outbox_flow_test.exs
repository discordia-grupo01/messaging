defmodule Messaging.Chat.OutboxFlowTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Mox

  alias Messaging.Chat
  alias Messaging.Chat.{Conversation, Message}

  setup :verify_on_exit!

  setup do
    Messaging.SuspensionHelper.stub_active()
    stub(Messaging.Chat.RepoMock, :get_clock, fn _key -> nil end)
    stub(Messaging.Chat.RepoMock, :get_word_filter, fn _server_id -> {:ok, []} end)
    stub(Messaging.Chat.RepoMock, :get_blocks, fn _ids -> {:ok, []} end)

    stub(Messaging.Chat.RepoMock, :get_channel, fn
      "chan-1" -> text_channel()
      id -> dm_channel(id)
    end)

    stub(Messaging.Chat.PermissionsStoreMock, :can_send_messages?, fn _c, _u -> {:ok, true} end)
    stub(Messaging.Chat.PermissionsStoreMock, :can_view_channel?, fn _c, _u -> {:ok, true} end)
    stub(Messaging.Chat.RepoMock, :delete_mentions, fn _id, _ids -> :ok end)
    stub(Messaging.Chat.RepoMock, :delete_reactions, fn _id -> :ok end)
    :ok
  end

  @user "user-1"
  @other "user-2"

  defp text_channel,
    do: %{"_id" => "chan-1", "server_id" => "srv-1", "name" => "general", "kind" => "text"}

  defp dm_channel(id),
    do: %{
      "_id" => id,
      "server_id" => nil,
      "name" => "",
      "kind" => "dm",
      "participants" => [@user, @other]
    }

  defp stored_doc,
    do: %{
      "_id" => "msg-1",
      "channel_id" => "chan-1",
      "server_id" => "srv-1",
      "user_id" => @user,
      "content" => "texto original",
      "inserted_at" => ~U[2026-09-28 12:00:00.000Z]
    }

  defp record_outbox do
    test_pid = self()

    stub(Messaging.Outbox.StoreMock, :insert, fn rows ->
      send(test_pid, {:outbox, rows})
      :ok
    end)
  end

  defp assert_outbox_written do
    {:messages, messages} = Process.info(self(), :messages)
    assert Enum.any?(messages, &match?({:outbox, _rows}, &1))
  end

  defp send_hola,
    do: Chat.send_message(%{channel_id: "chan-1", user_id: @user, content: "hola"})

  defp edit_to(content),
    do:
      Chat.edit_message(%{
        channel_id: "chan-1",
        message_id: "msg-1",
        user_id: @user,
        content: content
      })

  defp delete_it,
    do: Chat.delete_message(%{channel_id: "chan-1", message_id: "msg-1", user_id: @user})

  describe "a new message" do
    test "is recorded in the outbox with everything needed to finish it" do
      record_outbox()
      stub(Messaging.Chat.RepoMock, :insert_message, fn doc -> {:ok, doc} end)

      assert {:ok, %Message{id: id}} = send_hola()

      assert_received {:outbox, [row, _domain]}
      assert row.event == "new_message"
      assert row.topic == "channel:chan-1"
      assert row.message_id == id
      assert row.channel_id == "chan-1"
      assert row.payload["id"] == id
      assert row.payload["content"] == "hola"
      assert %{"op" => "insert_message", "doc" => doc} = row.apply
      assert doc["_id"] == id
      assert doc["content"] == "hola"
      assert {:ok, _datetime, _offset} = DateTime.from_iso8601(doc["inserted_at"])
    end

    test "tells the other services about it, with the ids and a short preview of the text" do
      record_outbox()
      stub(Messaging.Chat.RepoMock, :insert_message, fn doc -> {:ok, doc} end)

      assert {:ok, %Message{id: id, inserted_at: inserted_at}} = send_hola()

      assert_received {:outbox, [_created, domain]}
      assert domain.event == "messaging.message_created"
      assert domain.topic == "domain"
      assert domain.message_id == id
      assert domain.channel_id == "chan-1"
      assert is_nil(Map.get(domain, :apply))

      assert domain.payload == %{
               "occurred_at" => DateTime.to_iso8601(inserted_at),
               "server_id" => "srv-1",
               "channel_id" => "chan-1",
               "message_id" => id,
               "author_id" => @user,
               "mentioned_user_ids" => [],
               "channel_name" => "general",
               "content_preview" => "hola"
             }
    end

    test "carries the users it mentions, as already validated by the resolver" do
      record_outbox()
      stub(Messaging.Chat.RepoMock, :insert_message, fn doc -> {:ok, doc} end)

      stub(Messaging.Chat.RepoMock, :insert_mentions, fn docs ->
        {:ok, Enum.map(docs, & &1["_id"])}
      end)

      expect(Messaging.Chat.MentionResolverMock, :resolve, fn %{channel_id: "chan-1"},
                                                              _query,
                                                              _ ->
        {:ok,
         struct!(Messaging.Chat.Mentions.none(),
           user_ids: ["user-2", "user-3"],
           recipient_ids: ["user-2"]
         )}
      end)

      assert {:ok, %Message{id: id}} =
               Chat.send_message(%{
                 channel_id: "chan-1",
                 user_id: @user,
                 content: "hola <@user-2> <@user-3>"
               })

      assert_received {:outbox, [_created, domain]}
      assert domain.payload["message_id"] == id
      assert domain.payload["mentioned_user_ids"] == ["user-2"]
      assert domain.payload["content_preview"] == "hola @usuario @usuario"
      refute inspect(domain.payload) =~ "<@user"
    end

    test "the order really is outbox, then Mongo" do
      record_outbox()

      stub(Messaging.Chat.RepoMock, :insert_message, fn doc ->
        assert_outbox_written()
        {:ok, doc}
      end)

      assert {:ok, _message} = send_hola()
    end

    test "Mongo is never touched if the event cannot be recorded" do
      Messaging.OutboxHelper.stub_outbox_failing()

      capture_log(fn -> assert {:error, :messages_unavailable} = send_hola() end)
    end

    test "a direct message records the message, one notification per participant and the domain event at once" do
      record_outbox()
      stub(Messaging.Chat.RepoMock, :insert_message, fn doc -> {:ok, doc} end)
      stub(Messaging.Chat.RepoMock, :record_last_message, fn _, _, _, _ -> :ok end)

      assert {:ok, _channel, %Message{id: id}} =
               Chat.send_direct_message(%{sender_id: @user, recipient_id: @other, content: "hola"})

      conversation = Conversation.id(@user, @other)
      assert_received {:outbox, rows}

      assert Enum.map(rows, & &1.event) ==
               ["new_message", "new_dm", "new_dm", "messaging.direct_message_created"]

      assert Enum.map(rows, & &1.topic) ==
               ["channel:" <> conversation, "user:" <> @user, "user:" <> @other, "domain"]

      assert Enum.all?(rows, &(&1.message_id == id))

      [_message, mine, theirs, _domain] = rows
      assert mine.payload["partner_id"] == @other
      assert theirs.payload["partner_id"] == @user
      assert mine.payload["conversation_id"] == conversation
      assert mine.payload["message"]["id"] == id
      assert is_nil(Map.get(mine, :apply)) and is_nil(Map.get(theirs, :apply))
    end

    test "a direct message tells the other services who wrote to whom, with a short preview of the text" do
      record_outbox()
      stub(Messaging.Chat.RepoMock, :insert_message, fn doc -> {:ok, doc} end)
      stub(Messaging.Chat.RepoMock, :record_last_message, fn _, _, _, _ -> :ok end)

      assert {:ok, _channel, %Message{id: id, inserted_at: inserted_at}} =
               Chat.send_direct_message(%{sender_id: @user, recipient_id: @other, content: "hola"})

      assert_received {:outbox, rows}
      domain = List.last(rows)

      assert domain.event == "messaging.direct_message_created"
      assert domain.message_id == id
      assert domain.channel_id == Conversation.id(@user, @other)
      assert is_nil(Map.get(domain, :apply))

      assert domain.payload == %{
               "occurred_at" => DateTime.to_iso8601(inserted_at),
               "conversation_id" => Conversation.id(@user, @other),
               "message_id" => id,
               "author_id" => @user,
               "recipient_id" => @other,
               "content_preview" => "hola"
             }
    end
  end

  describe "an edit" do
    test "is recorded with the new content, and applied to Mongo only after" do
      record_outbox()
      stub(Messaging.Chat.RepoMock, :get_message, fn "msg-1" -> stored_doc() end)

      stub(Messaging.Chat.RepoMock, :update_message, fn "msg-1",
                                                        "chan-1",
                                                        @user,
                                                        content,
                                                        at,
                                                        fields ->
        assert_outbox_written()

        {:ok,
         stored_doc()
         |> Map.merge(fields)
         |> Map.merge(%{"content" => content, "edited_at" => at})}
      end)

      assert {:ok, %Message{content: "nuevo"}, :updated} = edit_to("nuevo")

      assert_received {:outbox, [row]}
      assert row.event == "message_updated"
      assert row.topic == "channel:chan-1"
      assert row.message_id == "msg-1"
      assert row.payload["content"] == "nuevo"
      assert row.payload["edited"] == true

      assert %{
               "op" => "update_message",
               "id" => "msg-1",
               "channel_id" => "chan-1",
               "fields" => fields
             } =
               row.apply

      assert fields["content"] == "nuevo"
      assert {:ok, _, _} = DateTime.from_iso8601(fields["edited_at"])
      assert {:ok, _, _} = DateTime.from_iso8601(fields["changed_at"])
    end

    test "nothing is recorded when the content did not change" do
      stub(Messaging.Chat.RepoMock, :get_message, fn "msg-1" -> stored_doc() end)

      assert {:ok, %Message{}, :unchanged} = edit_to("texto original")
    end

    test "Mongo is never touched if the event cannot be recorded" do
      Messaging.OutboxHelper.stub_outbox_failing()
      stub(Messaging.Chat.RepoMock, :get_message, fn "msg-1" -> stored_doc() end)

      capture_log(fn -> assert {:error, :messages_unavailable} = edit_to("nuevo") end)
    end
  end

  describe "a deletion" do
    test "is recorded without the content, and applied to Mongo only after" do
      record_outbox()
      stub(Messaging.Chat.RepoMock, :get_message, fn "msg-1" -> stored_doc() end)

      stub(Messaging.Chat.RepoMock, :delete_message, fn "msg-1", "chan-1", at ->
        assert_outbox_written()
        {:ok, Map.merge(stored_doc(), %{"content" => "", "deleted_at" => at})}
      end)

      assert {:ok, %Message{deleted_at: %DateTime{}}} = delete_it()

      assert_received {:outbox, [row]}
      assert row.event == "message_deleted"
      assert row.topic == "channel:chan-1"
      assert row.message_id == "msg-1"
      assert row.payload["id"] == "msg-1"
      refute Map.has_key?(row.payload, "content")

      assert %{
               "op" => "delete_message",
               "id" => "msg-1",
               "channel_id" => "chan-1",
               "deleted_at" => at
             } =
               row.apply

      assert {:ok, _, _} = DateTime.from_iso8601(at)
    end

    test "Mongo is never touched if the event cannot be recorded" do
      Messaging.OutboxHelper.stub_outbox_failing()
      stub(Messaging.Chat.RepoMock, :get_message, fn "msg-1" -> stored_doc() end)

      capture_log(fn -> assert {:error, :messages_unavailable} = delete_it() end)
    end
  end
end
