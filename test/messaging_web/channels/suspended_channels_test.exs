defmodule MessagingWeb.SuspendedChannelsTest do
  use MessagingWeb.ChannelCase
  import ExUnit.CaptureLog
  import Mox

  alias Messaging.AuthFixtures
  alias Messaging.SuspensionHelper
  alias MessagingWeb.{RoomChannel, UserChannel, UserSocket}

  setup :set_mox_global
  setup :verify_on_exit!

  @me "11111111-1111-4111-8111-111111111111"
  @other "22222222-2222-4222-8222-222222222222"
  @channel_id "chan-1"

  setup do
    stub(Messaging.Chat.RepoMock, :get_clock, fn _key -> nil end)

    stub(Messaging.Chat.RepoMock, :get_channel, fn @channel_id ->
      %{"_id" => @channel_id, "server_id" => "srv-1", "name" => "general", "kind" => "text"}
    end)

    stub(Messaging.Chat.RepoMock, :list_messages, fn _channel, _opts -> {:ok, []} end)
    stub(Messaging.Chat.RepoMock, :list_reactions, fn _ids -> {:ok, []} end)

    stub(Messaging.Chat.PermissionsStoreMock, :can_view_channel?, fn _channel, _uid ->
      {:ok, true}
    end)

    :ok
  end

  defp ticket_for(user_id) do
    stub(Messaging.Auth.TicketStoreMock, :take, fn _id ->
      {:ok, AuthFixtures.ticket_doc(user_id)}
    end)
  end

  defp socket_for(user_id) do
    ticket_for(user_id)
    {:ok, socket} = connect(UserSocket, %{"ticket" => "a-ticket"})
    socket
  end

  describe "UserSocket.connect/3" do
    test "refuses a valid ticket issued before the suspension" do
      ticket_for(@me)
      SuspensionHelper.stub_suspended(@me)

      assert :error = connect(UserSocket, %{"ticket" => "a-ticket"})
    end

    test "refuses the connection when the state cannot be read" do
      ticket_for(@me)
      SuspensionHelper.stub_suspension_check_failing()

      log =
        capture_log(fn ->
          assert :error = connect(UserSocket, %{"ticket" => "a-ticket"})
        end)

      assert log =~ "suspension_check_failed"
    end

    test "still accepts a user who is not suspended" do
      SuspensionHelper.stub_suspended(@other)
      ticket_for(@me)

      assert {:ok, %{assigns: %{user_id: @me}}} = connect(UserSocket, %{"ticket" => "a-ticket"})
    end
  end

  describe "RoomChannel" do
    test "join is refused to a suspended user" do
      socket = socket_for(@me)
      SuspensionHelper.stub_suspended(@me)

      assert {:error, %{error: %{code: "ACCOUNT_SUSPENDED"}}} =
               subscribe_and_join(socket, RoomChannel, "channel:" <> @channel_id)
    end

    for {event, payload} <- [
          {"new_message", %{"content" => "hola"}},
          {"edit_message", %{"id" => "m1", "content" => "nuevo"}},
          {"delete_message", %{"id" => "m1"}},
          {"add_reaction", %{"message_id" => "m1", "emoji" => "👍"}},
          {"remove_reaction", %{"message_id" => "m1", "emoji" => "👍"}}
        ] do
      test "#{event} is refused once the user is suspended, over an already open socket" do
        socket = socket_for(@me)
        {:ok, _reply, joined} = subscribe_and_join(socket, RoomChannel, "channel:" <> @channel_id)

        SuspensionHelper.stub_suspended(@me)
        ref = push(joined, unquote(event), unquote(Macro.escape(payload)))

        assert_reply ref, :error, %{error: %{code: "ACCOUNT_SUSPENDED"}}
      end
    end

    test "writes fail closed when the state cannot be read" do
      socket = socket_for(@me)
      {:ok, _reply, joined} = subscribe_and_join(socket, RoomChannel, "channel:" <> @channel_id)

      SuspensionHelper.stub_suspension_check_failing()

      capture_log(fn ->
        ref = push(joined, "new_message", %{"content" => "hola"})
        assert_reply ref, :error, %{error: %{code: "SUSPENSION_UNAVAILABLE"}}
      end)
    end
  end

  describe "UserChannel" do
    test "join is refused to a suspended user" do
      socket = socket_for(@me)
      SuspensionHelper.stub_suspended(@me)

      assert {:error, %{error: %{code: "ACCOUNT_SUSPENDED"}}} =
               subscribe_and_join(socket, UserChannel, "user:" <> @me)
    end

    test "send_dm is refused once the user is suspended" do
      socket = socket_for(@me)
      {:ok, _reply, joined} = subscribe_and_join(socket, UserChannel, "user:" <> @me)

      SuspensionHelper.stub_suspended(@me)
      ref = push(joined, "send_dm", %{"to" => @other, "content" => "hola"})

      assert_reply ref, :error, %{error: %{code: "ACCOUNT_SUSPENDED"}}
    end

    test "send_dm fails closed when the state cannot be read" do
      socket = socket_for(@me)
      {:ok, _reply, joined} = subscribe_and_join(socket, UserChannel, "user:" <> @me)

      SuspensionHelper.stub_suspension_check_failing()

      capture_log(fn ->
        ref = push(joined, "send_dm", %{"to" => @other, "content" => "hola"})
        assert_reply ref, :error, %{error: %{code: "SUSPENSION_UNAVAILABLE"}}
      end)
    end
  end
end
