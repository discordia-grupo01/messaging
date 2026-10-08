defmodule Messaging.Events.LifecycleTest do
  use ExUnit.Case, async: false
  import Mox

  alias Messaging.Events.{ChannelEvent, Lifecycle}

  setup :verify_on_exit!

  @t1 ~U[2026-10-06 12:00:00.000Z]

  defp created(overrides \\ %{}) do
    struct!(
      ChannelEvent.ChannelCreated,
      Map.merge(
        %{
          event_id: "e1",
          occurred_at: @t1,
          server_id: "srv-1",
          channel_id: "c-1",
          name: "general",
          kind: "text"
        },
        overrides
      )
    )
  end

  defp deleted(overrides \\ %{}),
    do:
      struct!(
        ChannelEvent.ChannelDeleted,
        Map.merge(
          %{event_id: "e2", occurred_at: @t1, server_id: "srv-1", channel_id: "c-1"},
          overrides
        )
      )

  defp member(module, overrides \\ %{}),
    do:
      struct!(
        module,
        Map.merge(
          %{event_id: "e3", occurred_at: @t1, server_id: "srv-1", user_id: "user-1"},
          overrides
        )
      )

  describe "channel_created" do
    test "an event that is newer than what we know is applied" do
      expect(Messaging.Chat.RepoMock, :get_clock, fn "server:srv-1" -> nil end)

      expect(Messaging.Chat.RepoMock, :apply_clock, fn "channel:c-1", "created", @t1, nil ->
        {:ok, :applied}
      end)

      expect(Messaging.Chat.RepoMock, :upsert_channel, fn %{
                                                            "_id" => "c-1",
                                                            "server_id" => "srv-1"
                                                          } ->
        :ok
      end)

      assert :ok = Lifecycle.handle(created())
    end

    test "one that arrives after its channel was deleted is dropped, without touching the cache" do
      expect(Messaging.Chat.RepoMock, :get_clock, fn _key -> nil end)

      expect(Messaging.Chat.RepoMock, :apply_clock, fn _k, "created", _at, nil ->
        {:ok, :stale}
      end)

      assert {:ignored, :stale} = Lifecycle.handle(created())
    end

    test "one for a server that was already deleted is dropped" do
      expect(Messaging.Chat.RepoMock, :get_clock, fn "server:srv-1" -> %{"state" => "deleted"} end)

      assert {:ignored, :server_deleted} = Lifecycle.handle(created())
    end

    test "repository failures are returned, never swallowed" do
      expect(Messaging.Chat.RepoMock, :get_clock, fn _key -> {:error, :timeout} end)
      assert {:error, :timeout} = Lifecycle.handle(created())

      expect(Messaging.Chat.RepoMock, :get_clock, fn _key -> nil end)
      expect(Messaging.Chat.RepoMock, :apply_clock, fn _k, _s, _a, _e -> {:error, :timeout} end)
      assert {:error, :timeout} = Lifecycle.handle(created())

      expect(Messaging.Chat.RepoMock, :get_clock, fn _key -> nil end)
      expect(Messaging.Chat.RepoMock, :apply_clock, fn _k, _s, _a, _e -> {:ok, :applied} end)
      expect(Messaging.Chat.RepoMock, :upsert_channel, fn _doc -> {:error, :timeout} end)
      assert {:error, :timeout} = Lifecycle.handle(created())
    end
  end

  describe "channel_deleted" do
    test "deletes the channel, leaves a tombstone that expires, and closes the sockets" do
      MessagingWeb.Endpoint.subscribe("channel:c-1")

      expect(Messaging.Chat.RepoMock, :apply_clock, fn "channel:c-1",
                                                       "deleted",
                                                       @t1,
                                                       %DateTime{} = expires ->
        assert DateTime.diff(expires, DateTime.utc_now(), :day) in 6..7
        {:ok, :applied}
      end)

      expect(Messaging.Chat.RepoMock, :delete_channel, fn "c-1" -> :ok end)

      assert :ok = Lifecycle.handle(deleted())

      assert_receive %Phoenix.Socket.Broadcast{
        event: "access_revoked",
        payload: %{"reason" => "channel_deleted", "user_id" => nil}
      }
    end

    test "a stale one changes nothing and closes nothing" do
      MessagingWeb.Endpoint.subscribe("channel:c-1")
      expect(Messaging.Chat.RepoMock, :apply_clock, fn _k, "deleted", _a, _e -> {:ok, :stale} end)

      assert {:ignored, :stale} = Lifecycle.handle(deleted())
      refute_receive %Phoenix.Socket.Broadcast{}, 50
    end
  end

  describe "server_deleted" do
    test "closes the event's channels and the ones only the cache knew about" do
      for id <- ["c-1", "c-2", "c-3"], do: MessagingWeb.Endpoint.subscribe("channel:" <> id)

      event =
        struct!(ChannelEvent.ServerDeleted,
          event_id: "e4",
          occurred_at: @t1,
          server_id: "srv-1",
          channel_ids: ["c-1", "c-2"]
        )

      expect(Messaging.Chat.RepoMock, :apply_clock, fn "server:srv-1",
                                                       "deleted",
                                                       @t1,
                                                       %DateTime{} ->
        {:ok, :applied}
      end)

      expect(Messaging.Chat.RepoMock, :list_channel_ids, fn "srv-1" -> {:ok, ["c-2", "c-3"]} end)
      expect(Messaging.Chat.RepoMock, :delete_server_data, fn "srv-1", ["c-1", "c-2"] -> :ok end)

      assert :ok = Lifecycle.handle(event)

      for id <- ["c-1", "c-2", "c-3"] do
        assert_receive %Phoenix.Socket.Broadcast{
          topic: "channel:" <> ^id,
          event: "access_revoked",
          payload: %{"reason" => "server_deleted"}
        }
      end
    end

    test "a stale one is dropped" do
      event =
        struct!(ChannelEvent.ServerDeleted,
          event_id: "e4",
          occurred_at: @t1,
          server_id: "srv-1",
          channel_ids: []
        )

      expect(Messaging.Chat.RepoMock, :apply_clock, fn _k, _s, _a, _e -> {:ok, :stale} end)

      assert {:ignored, :stale} = Lifecycle.handle(event)
    end
  end

  describe "member_joined and member_left" do
    test "a join only records its place in the order" do
      expect(Messaging.Chat.RepoMock, :apply_clock, fn "member:srv-1:user-1",
                                                       "joined",
                                                       @t1,
                                                       nil ->
        {:ok, :applied}
      end)

      assert :ok = Lifecycle.handle(member(ChannelEvent.MemberJoined))
    end

    test "a stale join is dropped" do
      expect(Messaging.Chat.RepoMock, :apply_clock, fn _k, "joined", _a, _e -> {:ok, :stale} end)

      assert {:ignored, :stale} = Lifecycle.handle(member(ChannelEvent.MemberJoined))
    end

    test "a leave drops the user's mentions and closes only their sockets in that server" do
      MessagingWeb.Endpoint.subscribe("channel:c-1")

      expect(Messaging.Chat.RepoMock, :apply_clock, fn "member:srv-1:user-1", "left", @t1, nil ->
        {:ok, :applied}
      end)

      expect(Messaging.Chat.RepoMock, :delete_member_mentions, fn "srv-1", "user-1" -> :ok end)
      expect(Messaging.Chat.RepoMock, :list_channel_ids, fn "srv-1" -> {:ok, ["c-1"]} end)

      assert :ok = Lifecycle.handle(member(ChannelEvent.MemberLeft))

      assert_receive %Phoenix.Socket.Broadcast{
        event: "access_revoked",
        payload: %{"user_id" => "user-1", "reason" => "member_left", "channel_id" => "c-1"}
      }
    end

    test "a stale leave, from before a newer join, neither kicks anybody nor drops mentions" do
      MessagingWeb.Endpoint.subscribe("channel:c-1")
      expect(Messaging.Chat.RepoMock, :apply_clock, fn _k, "left", _a, _e -> {:ok, :stale} end)

      assert {:ignored, :stale} = Lifecycle.handle(member(ChannelEvent.MemberLeft))
      refute_receive %Phoenix.Socket.Broadcast{}, 50
    end

    test "if the sockets cannot be told, the error is returned so the event is retried" do
      previous = Application.get_env(:messaging, :broadcaster)
      Application.put_env(:messaging, :broadcaster, Messaging.FailingBroadcaster)
      on_exit(fn -> Application.put_env(:messaging, :broadcaster, previous) end)

      expect(Messaging.Chat.RepoMock, :apply_clock, fn _k, "left", _a, _e -> {:ok, :applied} end)
      expect(Messaging.Chat.RepoMock, :delete_member_mentions, fn _s, _u -> :ok end)
      expect(Messaging.Chat.RepoMock, :list_channel_ids, fn _s -> {:ok, ["c-1"]} end)

      assert {:error, :not_connected} = Lifecycle.handle(member(ChannelEvent.MemberLeft))
    end
  end
end
