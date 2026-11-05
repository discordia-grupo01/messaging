defmodule Messaging.Chat.AttachmentsFlowTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Mox

  alias Messaging.Chat
  alias Messaging.Chat.{Attachment, Conversation, Message}
  alias Messaging.FileFixtures

  setup :verify_on_exit!

  setup do
    Messaging.OutboxHelper.stub_outbox()
    Messaging.SuspensionHelper.stub_active()
    :ok
  end

  setup do
    stub(Messaging.Chat.RepoMock, :get_clock, fn _key -> nil end)
    stub(Messaging.Chat.RepoMock, :get_word_filter, fn _server_id -> {:ok, []} end)
    stub(Messaging.Chat.RepoMock, :premium?, fn _user -> false end)
    :ok
  end

  @channel_id "chan-1"
  @server_id "srv-1"
  @user "user-1"
  @other "user-2"

  defp text_channel(overrides \\ %{}),
    do:
      Map.merge(
        %{"_id" => @channel_id, "server_id" => @server_id, "name" => "general", "kind" => "text"},
        overrides
      )

  defp allow_upload do
    stub(Messaging.Chat.RepoMock, :get_channel, fn @channel_id -> text_channel() end)

    stub(Messaging.Chat.PermissionsStoreMock, :can_send_messages?, fn _channel, @user ->
      {:ok, true}
    end)
  end

  describe "prepare_upload/2 for a server channel" do
    test "returns the channel when the user may write there" do
      allow_upload()

      assert {:ok, @channel_id} = Chat.prepare_upload({:channel, @channel_id}, @user)
    end

    test "a user without SEND_MESSAGES cannot upload" do
      stub(Messaging.Chat.RepoMock, :get_channel, fn _id -> text_channel() end)

      stub(Messaging.Chat.PermissionsStoreMock, :can_send_messages?, fn _c, _u -> {:ok, false} end)

      assert {:error, :forbidden} = Chat.prepare_upload({:channel, @channel_id}, @user)
    end

    test "a muted member cannot upload" do
      stub(Messaging.Chat.RepoMock, :get_channel, fn _id -> text_channel() end)

      stub(Messaging.Chat.RepoMock, :get_clock, fn "member_mute:srv-1:user-1" ->
        %{"state" => "muted", "expires_at" => DateTime.add(DateTime.utc_now(), 600, :second)}
      end)

      assert {:error, :member_muted} = Chat.prepare_upload({:channel, @channel_id}, @user)
    end

    test "a voice channel or an unknown channel is not a valid destination" do
      stub(Messaging.Chat.RepoMock, :get_channel, fn
        "voice-1" -> text_channel(%{"_id" => "voice-1", "kind" => "voice"})
        "ghost" -> nil
      end)

      assert {:error, :channel_not_text} = Chat.prepare_upload({:channel, "voice-1"}, @user)
      assert {:error, :channel_not_found} = Chat.prepare_upload({:channel, "ghost"}, @user)
    end
  end

  describe "prepare_upload/2 for a direct message" do
    test "returns the conversation id, which is the same before the first message" do
      stub(Messaging.Chat.RepoMock, :get_blocks, fn _ids -> {:ok, []} end)
      stub(Messaging.Chat.RepoMock, :user_known?, fn @other -> true end)

      assert {:ok, id} = Chat.prepare_upload({:direct, @other}, @user)
      assert id == Conversation.id(@user, @other)
    end

    test "cannot upload to yourself, to a blocked user or to an unknown user" do
      assert {:error, :cannot_message_self} = Chat.prepare_upload({:direct, @user}, @user)

      stub(Messaging.Chat.RepoMock, :get_blocks, fn _ids ->
        {:ok, [%{"_id" => @user <> ":" <> @other}]}
      end)

      assert {:error, :user_blocked} = Chat.prepare_upload({:direct, @other}, @user)

      stub(Messaging.Chat.RepoMock, :get_blocks, fn _ids -> {:ok, []} end)
      stub(Messaging.Chat.RepoMock, :user_known?, fn _id -> false end)

      assert {:error, :recipient_not_found} = Chat.prepare_upload({:direct, @other}, @user)
    end
  end

  defp stored(key), do: %{url: "https://res.cloudinary.com/demo/" <> key, path: "image/x/" <> key}

  describe "store_attachment/4" do
    test "CA1: validates, uploads, and persists only the URL" do
      stub(Messaging.Chat.RepoMock, :count_pending_attachments, fn @user -> {:ok, 0} end)

      expect(Messaging.StorageMock, :put, fn key, body, content_type ->
        assert String.starts_with?(key, @channel_id <> "/")
        refute key =~ "foto"
        assert body == FileFixtures.png()
        assert content_type == "image/png"

        {:ok,
         %{
           url: "https://res.cloudinary.com/demo/image/upload/v1/discordia/" <> key <> ".png",
           path: "image/discordia/" <> key
         }}
      end)

      expect(Messaging.Chat.RepoMock, :insert_attachment, fn doc ->
        assert doc["user_id"] == @user
        assert doc["channel_id"] == @channel_id
        assert doc["name"] == "foto.png"
        assert doc["content_type"] == "image/png"
        assert doc["size"] == byte_size(FileFixtures.png())
        assert doc["url"] =~ "https://res.cloudinary.com/demo/image/upload/"
        assert doc["path"] =~ ~r{^image/discordia/chan-1/}
        assert doc["message_id"] == nil
        refute Enum.any?(Map.values(doc), &is_binary_content?/1)
        :ok
      end)

      assert {:ok, %Attachment{name: "foto.png", url: url, content_type: "image/png"}} =
               Chat.store_attachment(@channel_id, @user, "foto.png", FileFixtures.png())

      assert url =~ "https://res.cloudinary.com/demo"
    end

    defp is_binary_content?(value), do: is_binary(value) and value == FileFixtures.png()

    test "CA2: a format that is not allowed is rejected before touching storage or the database" do
      assert {:error, :unsupported_file_type} =
               Chat.store_attachment(@channel_id, @user, "virus.exe", "MZ" <> <<0, 0, 0>>)
    end

    test "CA2: an allowed extension does not hide another content" do
      assert {:error, :unsupported_file_type} =
               Chat.store_attachment(@channel_id, @user, "foto.png", "GIF89a" <> <<0, 0, 0>>)
    end

    test "CA3: a file over 10 MB is rejected before touching storage or the database" do
      big = FileFixtures.sized(:pdf, 10 * 1024 * 1024 + 1)

      assert {:error, :file_too_large} = Chat.store_attachment(@channel_id, @user, "a.pdf", big)
    end

    test "a Premium user can store a file over 10 MB" do
      stub(Messaging.Chat.RepoMock, :premium?, fn @user -> true end)
      stub(Messaging.Chat.RepoMock, :count_pending_attachments, fn @user -> {:ok, 0} end)
      stub(Messaging.Chat.RepoMock, :insert_attachment, fn _doc -> :ok end)

      stub(Messaging.StorageMock, :put, fn key, _body, _type ->
        {:ok, %{url: "https://cdn.test/" <> key, path: "supabase/" <> key}}
      end)

      big = FileFixtures.sized(:pdf, 10 * 1024 * 1024 + 1)

      assert {:ok, %Attachment{size: 10_485_761}} =
               Chat.store_attachment(@channel_id, @user, "a.pdf", big)
    end

    test "a file up to 10 MB doesn't need to look up Premium" do
      expect(Messaging.Chat.RepoMock, :premium?, 0, fn _user -> false end)
      stub(Messaging.Chat.RepoMock, :count_pending_attachments, fn @user -> {:ok, 0} end)
      stub(Messaging.Chat.RepoMock, :insert_attachment, fn _doc -> :ok end)

      stub(Messaging.StorageMock, :put, fn key, _body, _type ->
        {:ok, %{url: "https://cdn.test/" <> key, path: "image/" <> key}}
      end)

      assert {:ok, %Attachment{}} =
               Chat.store_attachment(@channel_id, @user, "a.png", FileFixtures.png())
    end

    test "an empty file is rejected" do
      assert {:error, :empty_file} = Chat.store_attachment(@channel_id, @user, "a.png", <<>>)
    end

    test "too many uploads waiting to be sent are refused" do
      stub(Messaging.Chat.RepoMock, :count_pending_attachments, fn _ -> {:ok, 20} end)

      assert {:error, :too_many_pending_attachments} =
               Chat.store_attachment(@channel_id, @user, "a.png", FileFixtures.png())
    end

    test "if storage fails nothing is saved and the error is an unavailable storage" do
      stub(Messaging.Chat.RepoMock, :count_pending_attachments, fn _ -> {:ok, 0} end)

      expect(Messaging.StorageMock, :put, fn _p, _b, _c -> {:error, {:unexpected_status, 500}} end)

      log =
        capture_log(fn ->
          assert {:error, :storage_unavailable} =
                   Chat.store_attachment(@channel_id, @user, "a.png", FileFixtures.png())
        end)

      assert log =~ "attachment_upload_failed"
    end

    test "if the database fails the uploaded file is removed so it is not orphaned" do
      stub(Messaging.Chat.RepoMock, :count_pending_attachments, fn _ -> {:ok, 0} end)
      expect(Messaging.StorageMock, :put, fn key, _b, _c -> {:ok, stored(key)} end)
      expect(Messaging.Chat.RepoMock, :insert_attachment, fn _doc -> {:error, :timeout} end)

      expect(Messaging.StorageMock, :delete, fn [path] ->
        assert path =~ ~r{^image/.+/chan-1/}
        :ok
      end)

      assert {:error, :timeout} =
               Chat.store_attachment(@channel_id, @user, "a.png", FileFixtures.png())
    end

    test "the name is sanitized before it is stored" do
      stub(Messaging.Chat.RepoMock, :count_pending_attachments, fn _ -> {:ok, 0} end)
      stub(Messaging.StorageMock, :put, fn key, _b, _c -> {:ok, stored(key)} end)

      expect(Messaging.Chat.RepoMock, :insert_attachment, fn doc ->
        assert doc["name"] == "passwd"
        refute doc["path"] =~ "passwd"
        :ok
      end)

      assert {:ok, _} =
               Chat.store_attachment(@channel_id, @user, "../../etc/passwd", FileFixtures.png())
    end
  end

  describe "send_message/1 with attachments" do
    defp attachment_doc(id),
      do: %{
        "_id" => id,
        "url" => "https://x/#{id}.png",
        "name" => "#{id}.png",
        "content_type" => "image/png",
        "size" => 10
      }

    defp send_with(content, ids),
      do:
        Chat.send_message(%{
          channel_id: @channel_id,
          user_id: @user,
          content: content,
          attachment_ids: ids
        })

    test "CA1: the message carries the attachments and they are claimed for it" do
      allow_upload()

      expect(Messaging.Chat.RepoMock, :claim_attachments, fn ["a1", "a2"],
                                                             @user,
                                                             @channel_id,
                                                             message_id ->
        send(self(), {:claimed_for, message_id})
        {:ok, [attachment_doc("a1"), attachment_doc("a2")]}
      end)

      expect(Messaging.Chat.RepoMock, :insert_message, fn doc ->
        assert [%{"id" => "a1"}, %{"id" => "a2"}] = doc["attachments"]
        assert doc["content"] == "mirá"
        {:ok, doc}
      end)

      assert {:ok, %Message{content: "mirá", id: id, attachments: [%{"id" => "a1"}, _]}} =
               send_with("mirá", ["a1", "a2"])

      assert_received {:claimed_for, ^id}
    end

    test "a message may have only attachments and no text" do
      allow_upload()

      expect(Messaging.Chat.RepoMock, :claim_attachments, fn _, _, _, _ ->
        {:ok, [attachment_doc("a1")]}
      end)

      expect(Messaging.Chat.RepoMock, :insert_message, fn doc -> {:ok, doc} end)

      assert {:ok, %Message{content: "", attachments: [%{"id" => "a1"}]}} =
               send_with("   ", ["a1"])
    end

    test "without text and without attachments the message is still empty" do
      allow_upload()

      assert {:error, :empty_content} = send_with("  ", [])
      assert {:error, :empty_content} = send_with("  ", nil)
    end

    test "more than 5 attachments are refused before anything is claimed" do
      allow_upload()

      assert {:error, :too_many_attachments} = send_with("x", ~w(a1 a2 a3 a4 a5 a6))
    end

    test "the same attachment listed twice counts once" do
      allow_upload()

      expect(Messaging.Chat.RepoMock, :claim_attachments, fn ["a1"], _, _, _ ->
        {:ok, [attachment_doc("a1")]}
      end)

      expect(Messaging.Chat.RepoMock, :insert_message, fn doc -> {:ok, doc} end)

      assert {:ok, %Message{attachments: [_one]}} = send_with("x", ["a1", "a1"])
    end

    test "ids that are not a list of strings are refused" do
      allow_upload()

      for bad <- ["a1", [1, 2], [%{"$ne" => 1}], [""], %{}] do
        assert {:error, :invalid_attachment} = send_with("x", bad)
      end
    end

    test "an attachment that is not the user's, is in another channel or was already used is refused" do
      allow_upload()

      expect(Messaging.Chat.RepoMock, :claim_attachments, fn _, _, _, _ ->
        {:error, :invalid_attachment}
      end)

      assert {:error, :invalid_attachment} = send_with("x", ["alien"])
    end

    test "if the message cannot be recorded the claim is released so they can be reused" do
      allow_upload()
      Messaging.OutboxHelper.stub_outbox_failing()

      expect(Messaging.Chat.RepoMock, :claim_attachments, fn _, _, _, _ ->
        {:ok, [attachment_doc("a1")]}
      end)

      expect(Messaging.Chat.RepoMock, :release_attachments, fn _message_id -> :ok end)

      capture_log(fn -> assert {:error, :messages_unavailable} = send_with("x", ["a1"]) end)
    end

    test "a user who cannot write there cannot use attachments either" do
      stub(Messaging.Chat.RepoMock, :get_channel, fn _ -> text_channel() end)

      stub(Messaging.Chat.PermissionsStoreMock, :can_send_messages?, fn _c, _u -> {:ok, false} end)

      assert {:error, :forbidden} = send_with("x", ["a1"])
    end

    test "messages without attachments never touch the attachments collection" do
      allow_upload()

      expect(Messaging.Chat.RepoMock, :insert_message, fn doc ->
        refute Map.has_key?(doc, "attachments")
        {:ok, doc}
      end)

      assert {:ok, %Message{attachments: []}} = send_with("hola", nil)
    end
  end

  describe "send_direct_message/1 with attachments" do
    test "CA1: a direct message can carry attachments too" do
      conversation = Conversation.id(@user, @other)
      stub(Messaging.Chat.RepoMock, :get_blocks, fn _ids -> {:ok, []} end)
      stub(Messaging.Chat.RepoMock, :get_channel, fn ^conversation -> nil end)
      stub(Messaging.Chat.RepoMock, :user_known?, fn _id -> true end)
      stub(Messaging.Chat.RepoMock, :ensure_conversation, fn _doc -> :ok end)
      stub(Messaging.Chat.RepoMock, :record_last_message, fn _, _, _, _ -> :ok end)

      expect(Messaging.Chat.RepoMock, :claim_attachments, fn ["a1"], @user, ^conversation, _ ->
        {:ok, [attachment_doc("a1")]}
      end)

      expect(Messaging.Chat.RepoMock, :insert_message, fn doc -> {:ok, doc} end)

      assert {:ok, _channel, %Message{content: "", attachments: [%{"id" => "a1"}]}} =
               Chat.send_direct_message(%{
                 sender_id: @user,
                 recipient_id: @other,
                 content: "",
                 attachment_ids: ["a1"]
               })
    end
  end

  describe "edit_message/1 and delete_message/1 with attachments" do
    defp stored_message(attachments) do
      %{
        "_id" => "msg-1",
        "channel_id" => @channel_id,
        "server_id" => @server_id,
        "user_id" => @user,
        "content" => "hola",
        "inserted_at" => ~U[2026-10-12 12:00:00.000Z],
        "attachments" => attachments
      }
    end

    test "the text of a message that has attachments can be emptied" do
      allow_upload()

      stub(Messaging.Chat.RepoMock, :get_message, fn "msg-1" ->
        stored_message([attachment_doc("a1")])
      end)

      expect(Messaging.Chat.RepoMock, :update_message, fn "msg-1", _, @user, "", _at, _fields ->
        {:ok, Map.merge(stored_message([attachment_doc("a1")]), %{"content" => ""})}
      end)

      stub(Messaging.Chat.RepoMock, :delete_mentions, fn _, _ -> :ok end)

      assert {:ok, %Message{content: "", attachments: [_one]}, :updated} =
               Chat.edit_message(%{
                 channel_id: @channel_id,
                 message_id: "msg-1",
                 user_id: @user,
                 content: "  "
               })
    end

    test "without attachments an edit still cannot leave the message empty" do
      allow_upload()
      stub(Messaging.Chat.RepoMock, :get_message, fn "msg-1" -> stored_message([]) end)

      assert {:error, :empty_content} =
               Chat.edit_message(%{
                 channel_id: @channel_id,
                 message_id: "msg-1",
                 user_id: @user,
                 content: ""
               })
    end

    test "deleting a message marks its files so the cleaner removes them from storage" do
      allow_upload()

      stub(Messaging.Chat.RepoMock, :get_message, fn "msg-1" ->
        stored_message([attachment_doc("a1")])
      end)

      stub(Messaging.Chat.PermissionsStoreMock, :can_view_channel?, fn _c, _u -> {:ok, true} end)

      expect(Messaging.Chat.RepoMock, :delete_message, fn "msg-1", @channel_id, _at ->
        {:ok,
         Map.merge(stored_message([]), %{"content" => "", "deleted_at" => DateTime.utc_now()})}
      end)

      stub(Messaging.Chat.RepoMock, :delete_mentions, fn _, _ -> :ok end)
      stub(Messaging.Chat.RepoMock, :delete_reactions, fn _ -> :ok end)

      expect(Messaging.Chat.RepoMock, :orphan_message_attachments, fn "msg-1", %DateTime{} ->
        :ok
      end)

      assert {:ok, %Message{attachments: []}} =
               Chat.delete_message(%{channel_id: @channel_id, message_id: "msg-1", user_id: @user})
    end

    test "deleting a message without files does not touch attachments" do
      allow_upload()
      stub(Messaging.Chat.RepoMock, :get_message, fn "msg-1" -> stored_message([]) end)
      stub(Messaging.Chat.PermissionsStoreMock, :can_view_channel?, fn _c, _u -> {:ok, true} end)

      stub(Messaging.Chat.RepoMock, :delete_message, fn _, _, _ ->
        {:ok, Map.merge(stored_message([]), %{"deleted_at" => DateTime.utc_now()})}
      end)

      stub(Messaging.Chat.RepoMock, :delete_mentions, fn _, _ -> :ok end)
      stub(Messaging.Chat.RepoMock, :delete_reactions, fn _ -> :ok end)

      assert {:ok, _} =
               Chat.delete_message(%{channel_id: @channel_id, message_id: "msg-1", user_id: @user})
    end
  end
end
