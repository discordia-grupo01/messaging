defmodule Messaging.Chat.PrivateVoiceTest do
  use ExUnit.Case, async: false
  import Mox

  alias Messaging.Chat

  setup :verify_on_exit!

  setup do
    Messaging.SuspensionHelper.stub_active()
    :ok
  end

  @caller "11111111-1111-4111-8111-111111111111"
  @recipient "22222222-2222-4222-8222-222222222222"
  @conversation "33333333-3333-4333-8333-333333333333"

  defp conversation_doc,
    do: %{
      "_id" => @conversation,
      "server_id" => nil,
      "name" => "",
      "kind" => "dm",
      "participants" => [@caller, @recipient]
    }

  test "allows a private call for both participants when neither blocked the other" do
    expect(Messaging.Chat.RepoMock, :get_channel, fn @conversation -> conversation_doc() end)

    expect(Messaging.Chat.RepoMock, :get_blocks, fn ids ->
      assert Enum.sort(ids) ==
               Enum.sort([@caller <> ":" <> @recipient, @recipient <> ":" <> @caller])

      {:ok, []}
    end)

    assert :ok = Chat.authorize_private_voice(@caller, @recipient, @conversation)
  end

  test "rejects a call when the caller blocked the recipient" do
    expect(Messaging.Chat.RepoMock, :get_channel, fn @conversation -> conversation_doc() end)

    expect(Messaging.Chat.RepoMock, :get_blocks, fn _ids ->
      {:ok, [%{"_id" => @caller <> ":" <> @recipient}]}
    end)

    assert {:error, :forbidden} =
             Chat.authorize_private_voice(@caller, @recipient, @conversation)
  end

  test "rejects a call when the recipient blocked the caller" do
    expect(Messaging.Chat.RepoMock, :get_channel, fn @conversation -> conversation_doc() end)

    expect(Messaging.Chat.RepoMock, :get_blocks, fn _ids ->
      {:ok, [%{"_id" => @recipient <> ":" <> @caller}]}
    end)

    assert {:error, :forbidden} =
             Chat.authorize_private_voice(@caller, @recipient, @conversation)
  end

  test "rejects a server channel or a non-participant" do
    expect(Messaging.Chat.RepoMock, :get_channel, fn @conversation ->
      %{conversation_doc() | "server_id" => "server-1"}
    end)

    assert {:error, :forbidden} =
             Chat.authorize_private_voice(@caller, @recipient, @conversation)

    expect(Messaging.Chat.RepoMock, :get_channel, fn @conversation ->
      %{conversation_doc() | "participants" => [@caller, "other"]}
    end)

    assert {:error, :forbidden} =
             Chat.authorize_private_voice(@caller, @recipient, @conversation)
  end
end
