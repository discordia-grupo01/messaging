defmodule MessagingWeb.MentionPushTest do
  use MessagingWeb.ChannelCase
  import Mox

  alias Messaging.AuthFixtures
  alias Messaging.Chat.Mentions
  alias MessagingWeb.{RoomChannel, UserChannel}

  setup :set_mox_global
  setup :verify_on_exit!

  @channel_id "chan-push"
  @server_id "srv-push"
  @author "author-push"
  @ana "ana-push"
  @bob "bob-push"

  setup do
    stub(Messaging.Chat.RepoMock, :get_clock, fn _key -> nil end)

    stub(Messaging.Chat.RepoMock, :get_channel, fn @channel_id ->
      %{"_id" => @channel_id, "server_id" => @server_id, "name" => "general", "kind" => "text"}
    end)

    stub(Messaging.Chat.PermissionsClientMock, :can_send_messages?, fn _, _, _ -> {:ok, true} end)
    stub(Messaging.Chat.PermissionsClientMock, :can_view_channel?, fn _, _, _ -> {:ok, true} end)
    stub(Messaging.Chat.RepoMock, :insert_message, fn doc -> {:ok, doc} end)
    :ok
  end

  defp socket_for(user_id) do
    stub(Messaging.Auth.TicketStoreMock, :take, fn _id ->
      {:ok, AuthFixtures.ticket_doc(user_id)}
    end)

    {:ok, socket} = connect(MessagingWeb.UserSocket, %{"ticket" => "a-ticket"})
    socket
  end

  defp join_room(user_id) do
    {:ok, _reply, socket} =
      subscribe_and_join(socket_for(user_id), RoomChannel, "channel:" <> @channel_id)

    socket
  end

  defp join_own(user_id) do
    {:ok, _reply, socket} =
      subscribe_and_join(socket_for(user_id), UserChannel, "user:" <> user_id)

    socket
  end

  test "the mentioned member gets a `mention` push on their own topic" do
    expect(Messaging.Chat.MentionsClientMock, :resolve, fn @server_id, @channel_id, query, _jwt ->
      assert query == %{user_ids: [@ana], role_ids: [], everyone: false}
      {:ok, %{Mentions.none() | user_ids: [@ana], recipient_ids: [@ana]}}
    end)

    expect(Messaging.Chat.RepoMock, :insert_mentions, fn [%{"user_id" => @ana}] ->
      {:ok, [@ana]}
    end)

    room = join_room(@author)
    _ana = join_own(@ana)

    ref = push(room, "new_message", %{"content" => "<@#{@ana}> mirá esto"})
    assert_reply ref, :ok

    assert_push "new_message", %{"mentions" => [@ana], "user_id" => @author}

    assert_push "mention", %{
      "server_id" => @server_id,
      "channel_id" => @channel_id,
      "message" => %{"content" => "<@" <> _, "mentions" => [@ana], "user_id" => @author}
    }
  end

  test "@everyone with permission reaches everyone servers lists, each on their own topic" do
    expect(Messaging.Chat.MentionsClientMock, :resolve, fn _sid, _cid, _query, _jwt ->
      {:ok, %{Mentions.none() | everyone: true, recipient_ids: [@ana, @bob]}}
    end)

    expect(Messaging.Chat.RepoMock, :insert_mentions, fn docs ->
      {:ok, Enum.map(docs, & &1["user_id"])}
    end)

    room = join_room(@author)
    MessagingWeb.Endpoint.subscribe("user:" <> @ana)
    MessagingWeb.Endpoint.subscribe("user:" <> @bob)

    ref = push(room, "new_message", %{"content" => "@everyone mañana no hay clase"})
    assert_reply ref, :ok

    assert_receive %Phoenix.Socket.Broadcast{topic: "user:" <> @ana, event: "mention"}
    assert_receive %Phoenix.Socket.Broadcast{topic: "user:" <> @bob, event: "mention"}
  end

  test "CA4 over the socket: no permission means the message arrives as text and nobody is pinged" do
    expect(Messaging.Chat.MentionsClientMock, :resolve, fn _sid, _cid, _query, _jwt ->
      {:ok, Mentions.none()}
    end)

    room = join_room(@author)
    MessagingWeb.Endpoint.subscribe("user:" <> @ana)

    ref = push(room, "new_message", %{"content" => "@everyone hola"})
    assert_reply ref, :ok

    assert_push "new_message", %{"content" => "@everyone hola", "mention_everyone" => false}
    refute_receive %Phoenix.Socket.Broadcast{event: "mention"}, 100
  end

  test "if servers is down the author gets MENTIONS_UNAVAILABLE and nothing is sent" do
    expect(Messaging.Chat.MentionsClientMock, :resolve, fn _sid, _cid, _query, _jwt ->
      {:error, :timeout}
    end)

    room = join_room(@author)

    ref = push(room, "new_message", %{"content" => "<@#{@ana}>"})
    assert_reply ref, :error, %{error: %{code: "MENTIONS_UNAVAILABLE"}}
    refute_push "new_message", _
  end
end
