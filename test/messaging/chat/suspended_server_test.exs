defmodule Messaging.Chat.SuspendedServerTest do
  @moduledoc """
  Every operation on a channel of a server suspended by the platform staff is
  refused with `:server_suspended` as soon as the channel is resolved: the mocks
  have no other expectation, so any further read or write would fail the test.
  Direct messages have no server and are never affected.
  """
  use ExUnit.Case, async: true
  import Mox

  alias Messaging.Chat
  alias Messaging.SuspensionHelper

  setup :verify_on_exit!

  @user "11111111-1111-4111-8111-111111111111"
  @server "srv-1"
  @channel "chan-1"
  @other_server "srv-2"
  @other_channel "chan-2"
  @dm "dm-1"

  setup do
    SuspensionHelper.stub_active()
    SuspensionHelper.stub_server_suspended(@server)

    stub(Messaging.Chat.RepoMock, :get_channel, fn
      @channel ->
        text_channel(@channel, @server)

      @other_channel ->
        text_channel(@other_channel, @other_server)

      @dm ->
        %{
          "_id" => @dm,
          "server_id" => nil,
          "name" => "",
          "kind" => "dm",
          "participants" => [@user]
        }

      _other ->
        nil
    end)

    :ok
  end

  defp text_channel(id, server_id),
    do: %{"_id" => id, "server_id" => server_id, "name" => id, "kind" => "text"}

  describe "in a suspended server nobody" do
    test "can send a message" do
      assert {:error, :server_suspended} =
               Chat.send_message(%{channel_id: @channel, user_id: @user, content: "hola"})
    end

    test "can edit a message" do
      assert {:error, :server_suspended} =
               Chat.edit_message(%{
                 channel_id: @channel,
                 message_id: "m1",
                 user_id: @user,
                 content: "nuevo"
               })
    end

    test "can delete a message" do
      assert {:error, :server_suspended} =
               Chat.delete_message(%{channel_id: @channel, message_id: "m1", user_id: @user})
    end

    test "can react or remove a reaction" do
      params = %{channel_id: @channel, message_id: "m1", user_id: @user, emoji: "👍"}

      assert {:error, :server_suspended} = Chat.add_reaction(params)
      assert {:error, :server_suspended} = Chat.remove_reaction(params)
    end

    test "can prepare an upload" do
      assert {:error, :server_suspended} = Chat.prepare_upload({:channel, @channel}, @user)
    end

    test "can open the channel (history and join go through here)" do
      assert {:error, :server_suspended} = Chat.channel_exists?(@channel)
    end

    test "can mark the mentions of a channel as read" do
      assert {:error, :server_suspended} = Chat.mark_mentions_read(@channel, @user)
    end

    test "can search it" do
      assert {:error, :server_suspended} =
               Chat.search_messages(%{server_id: @server, user_id: @user, text: "hola"})
    end
  end

  describe "the lookup of messages by id" do
    test "leaves out the messages of a suspended server and keeps the rest" do
      at = ~U[2026-09-28 12:00:00Z]

      doc = fn id, channel ->
        %{
          "_id" => id,
          "channel_id" => channel,
          "server_id" => if(channel == @channel, do: @server, else: @other_server),
          "user_id" => @user,
          "content" => "mensaje #{id}",
          "inserted_at" => at
        }
      end

      expect(Messaging.Chat.RepoMock, :get_messages, fn ["m1", "m2"] ->
        {:ok, [doc.("m1", @channel), doc.("m2", @other_channel)]}
      end)

      stub(Messaging.Chat.PermissionsStoreMock, :can_view_channel?, fn _channel, _user ->
        {:ok, true}
      end)

      assert {:ok, [%{id: "m2"}]} = Chat.lookup_messages(["m1", "m2"], @user)
    end
  end

  describe "what is not affected" do
    test "another server" do
      assert {:ok, %{channel_id: @other_channel}} = Chat.channel_exists?(@other_channel)
    end

    test "a direct message, even if every server were suspended" do
      stub(Messaging.Chat.RepoMock, :server_suspended?, fn _server -> true end)

      assert {:ok, %{channel_id: @dm, server_id: nil}} = Chat.channel_exists?(@dm)
    end

    test "the same server once it is reactivated" do
      SuspensionHelper.stub_active()

      assert {:ok, %{channel_id: @channel}} = Chat.channel_exists?(@channel)
    end

    test "a channel that does not exist still is :channel_not_found" do
      assert {:error, :channel_not_found} = Chat.channel_exists?("nope")
    end
  end

  describe "the order of the checks" do
    test "a suspended account is told first" do
      SuspensionHelper.stub_suspended(@user)

      assert {:error, :account_suspended} =
               Chat.send_message(%{channel_id: @channel, user_id: @user, content: "hola"})
    end

    test "a channel that is not text keeps answering :channel_not_text" do
      stub(Messaging.Chat.RepoMock, :get_channel, fn "voice-1" ->
        %{"_id" => "voice-1", "server_id" => @server, "name" => "voz", "kind" => "voice"}
      end)

      assert {:error, :channel_not_text} = Chat.channel_exists?("voice-1")
    end
  end

  describe "when the state of the server cannot be read" do
    test "it fails closed with :suspension_unavailable and logs the cause" do
      SuspensionHelper.stub_server_suspension_check_failing()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :suspension_unavailable} = Chat.channel_exists?(@channel)

          assert {:error, :suspension_unavailable} =
                   Chat.send_message(%{channel_id: @channel, user_id: @user, content: "hola"})

          assert {:error, :suspension_unavailable} =
                   Chat.search_messages(%{server_id: @server, user_id: @user, text: "hola"})
        end)

      assert log =~ "server_suspension_check_failed"
    end
  end
end
