defmodule MessagingWeb.SuspendedServerChannelsTest do
  use MessagingWeb.ChannelCase
  import ExUnit.CaptureLog
  import Mox

  alias Messaging.AuthFixtures
  alias Messaging.Chat.Sockets
  alias Messaging.SuspensionHelper
  alias MessagingWeb.{RoomChannel, UserSocket}

  setup :set_mox_global
  setup :verify_on_exit!

  @me "11111111-1111-4111-8111-111111111111"
  @server "srv-1"
  @channel_id "chan-1"
  @other_server "srv-2"
  @other_channel "chan-2"

  setup do
    stub(Messaging.Chat.RepoMock, :get_clock, fn _key -> nil end)

    stub(Messaging.Chat.RepoMock, :get_channel, fn
      @channel_id ->
        %{"_id" => @channel_id, "server_id" => @server, "name" => "general", "kind" => "text"}

      @other_channel ->
        %{"_id" => @other_channel, "server_id" => @other_server, "name" => "b", "kind" => "text"}
    end)

    stub(Messaging.Chat.RepoMock, :list_messages, fn _channel, _opts -> {:ok, []} end)
    stub(Messaging.Chat.RepoMock, :list_reactions, fn _ids -> {:ok, []} end)
    stub(Messaging.Chat.RepoMock, :get_word_filter, fn _server -> {:ok, []} end)

    stub(Messaging.Chat.PermissionsStoreMock, :can_view_channel?, fn _channel, _uid ->
      {:ok, true}
    end)

    stub(Messaging.Chat.PermissionsStoreMock, :can_send_messages?, fn _channel, _uid ->
      {:ok, true}
    end)

    :ok
  end

  defp socket_for(user_id) do
    stub(Messaging.Auth.TicketStoreMock, :take, fn _id ->
      {:ok, AuthFixtures.ticket_doc(user_id)}
    end)

    {:ok, socket} = connect(UserSocket, %{"ticket" => "a-ticket"})
    socket
  end

  test "joining a channel of a suspended server is refused with SERVER_SUSPENDED" do
    SuspensionHelper.stub_server_suspended(@server)

    assert {:error, %{error: %{code: "SERVER_SUSPENDED"}}} =
             subscribe_and_join(socket_for(@me), RoomChannel, "channel:" <> @channel_id)
  end

  test "joining a channel of another server still works" do
    SuspensionHelper.stub_server_suspended(@server)

    assert {:ok, _reply, _socket} =
             subscribe_and_join(socket_for(@me), RoomChannel, "channel:" <> @other_channel)
  end

  test "joining fails closed when the state of the server cannot be read" do
    SuspensionHelper.stub_server_suspension_check_failing()

    capture_log(fn ->
      assert {:error, %{error: %{code: "SUSPENSION_UNAVAILABLE"}}} =
               subscribe_and_join(socket_for(@me), RoomChannel, "channel:" <> @channel_id)
    end)
  end

  test "joining works again once the server is reactivated" do
    SuspensionHelper.stub_server_suspended(@server)

    assert {:error, _} =
             subscribe_and_join(socket_for(@me), RoomChannel, "channel:" <> @channel_id)

    SuspensionHelper.stub_active()

    assert {:ok, _reply, _socket} =
             subscribe_and_join(socket_for(@me), RoomChannel, "channel:" <> @channel_id)
  end

  for {event, payload} <- [
        {"new_message", %{"content" => "hola"}},
        {"edit_message", %{"id" => "m1", "content" => "nuevo"}},
        {"delete_message", %{"id" => "m1"}},
        {"add_reaction", %{"message_id" => "m1", "emoji" => "👍"}},
        {"remove_reaction", %{"message_id" => "m1", "emoji" => "👍"}}
      ] do
    test "#{event} is refused over a socket that was already open when the server got suspended" do
      {:ok, _reply, joined} =
        subscribe_and_join(socket_for(@me), RoomChannel, "channel:" <> @channel_id)

      SuspensionHelper.stub_server_suspended(@server)
      ref = push(joined, unquote(event), unquote(Macro.escape(payload)))

      assert_reply ref, :error, %{error: %{code: "SERVER_SUSPENDED"}}
    end
  end

  test "closing the channels of the server stops the open sockets with the reason" do
    {:ok, _reply, joined} =
      subscribe_and_join(socket_for(@me), RoomChannel, "channel:" <> @channel_id)

    Process.flag(:trap_exit, true)
    assert :ok = Sockets.close_channels([@channel_id], "server_suspended")

    assert_push "access_revoked", %{"channel_id" => @channel_id, "reason" => "server_suspended"}
    assert_receive {:EXIT, pid, :shutdown} when pid == joined.channel_pid
  end
end
