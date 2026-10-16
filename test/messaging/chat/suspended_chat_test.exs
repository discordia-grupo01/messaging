defmodule Messaging.Chat.SuspendedChatTest do
  @moduledoc """
  Every write of `Messaging.Chat` refuses a suspended user before reading or
  writing anything else: the repo mock has no other expectation, so any further
  call would fail the test.
  """
  use ExUnit.Case, async: true
  import Mox

  alias Messaging.Chat
  alias Messaging.SuspensionHelper

  setup :verify_on_exit!

  @user "11111111-1111-4111-8111-111111111111"
  @other "22222222-2222-4222-8222-222222222222"

  describe "a suspended user" do
    setup do
      SuspensionHelper.stub_suspended(@user)
      :ok
    end

    test "cannot send a message" do
      assert {:error, :account_suspended} =
               Chat.send_message(%{channel_id: "c1", user_id: @user, content: "hola"})
    end

    test "cannot edit a message" do
      assert {:error, :account_suspended} =
               Chat.edit_message(%{
                 channel_id: "c1",
                 message_id: "m1",
                 user_id: @user,
                 content: "nuevo"
               })
    end

    test "cannot delete a message" do
      assert {:error, :account_suspended} =
               Chat.delete_message(%{channel_id: "c1", message_id: "m1", user_id: @user})
    end

    test "cannot react" do
      params = %{channel_id: "c1", message_id: "m1", user_id: @user, emoji: "👍"}

      assert {:error, :account_suspended} = Chat.add_reaction(params)
    end

    test "cannot remove a reaction" do
      params = %{channel_id: "c1", message_id: "m1", user_id: @user, emoji: "👍"}

      assert {:error, :account_suspended} = Chat.remove_reaction(params)
    end

    test "cannot send a direct message" do
      assert {:error, :account_suspended} =
               Chat.send_direct_message(%{sender_id: @user, recipient_id: @other, content: "hola"})
    end

    test "cannot upload an attachment" do
      assert {:error, :account_suspended} =
               Chat.store_attachment("c1", @user, "foto.png", Messaging.FileFixtures.png())
    end
  end

  describe "when the suspension state cannot be read" do
    setup do
      SuspensionHelper.stub_suspension_check_failing()
      :ok
    end

    test "writes fail closed with :suspension_unavailable and log the cause" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :suspension_unavailable} =
                   Chat.send_message(%{channel_id: "c1", user_id: @user, content: "hola"})

          assert {:error, :suspension_unavailable} =
                   Chat.send_direct_message(%{
                     sender_id: @user,
                     recipient_id: @other,
                     content: "hola"
                   })
        end)

      assert log =~ "suspension_check_failed"
    end
  end

  test "the user is only checked, not blamed: another user keeps writing" do
    SuspensionHelper.stub_suspended(@user)
    stub(Messaging.Chat.RepoMock, :get_channel, fn "c1" -> nil end)

    assert {:error, :channel_not_found} =
             Chat.send_message(%{channel_id: "c1", user_id: @other, content: "hola"})
  end
end
