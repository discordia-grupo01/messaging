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

      expect(Messaging.Chat.RepoMock, :delete_member, fn "srv-1", "user-1", @t1 ->
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

    test "a leave tells the user's personal room, so the server leaves their list" do
      MessagingWeb.Endpoint.subscribe("user:user-1")

      expect(Messaging.Chat.RepoMock, :apply_clock, fn _k, "left", _a, _e -> {:ok, :applied} end)
      expect(Messaging.Chat.RepoMock, :delete_member, fn _s, _u, _a -> {:ok, :applied} end)
      expect(Messaging.Chat.RepoMock, :delete_member_mentions, fn _s, _u -> :ok end)
      expect(Messaging.Chat.RepoMock, :list_channel_ids, fn _s -> {:ok, []} end)

      assert :ok = Lifecycle.handle(member(ChannelEvent.MemberLeft))

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "user:user-1",
        event: "server_left",
        payload: %{"server_id" => "srv-1"}
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
      expect(Messaging.Chat.RepoMock, :delete_member, fn _s, _u, _a -> {:ok, :applied} end)
      expect(Messaging.Chat.RepoMock, :delete_member_mentions, fn _s, _u -> :ok end)
      expect(Messaging.Chat.RepoMock, :list_channel_ids, fn _s -> {:ok, ["c-1"]} end)

      assert {:error, :not_connected} = Lifecycle.handle(member(ChannelEvent.MemberLeft))
    end
  end

  describe "permission replica events" do
    defp expect_alive do
      expect(Messaging.Chat.RepoMock, :get_clock, fn "server:srv-1" -> nil end)
    end

    test "a role snapshot is stored with its permissions" do
      expect_alive()

      expect(Messaging.Chat.RepoMock, :apply_role, fn "srv-1",
                                                      "role-1",
                                                      ["SEND_MESSAGES"],
                                                      false,
                                                      @t1 ->
        {:ok, :applied}
      end)

      event = %ChannelEvent.RoleUpdated{
        event_id: "r1",
        occurred_at: @t1,
        server_id: "srv-1",
        role_id: "role-1",
        permissions: ["SEND_MESSAGES"],
        is_everyone: false
      }

      assert :ok = Lifecycle.handle(event)
    end

    test "a role deleted removes it from the replica" do
      expect_alive()

      expect(Messaging.Chat.RepoMock, :delete_role, fn "srv-1", "role-1", @t1 ->
        {:ok, :applied}
      end)

      event = %ChannelEvent.RoleDeleted{
        event_id: "r2",
        occurred_at: @t1,
        server_id: "srv-1",
        role_id: "role-1"
      }

      assert :ok = Lifecycle.handle(event)
    end

    test "the roles of a member replace the ones we had" do
      expect_alive()

      expect(Messaging.Chat.RepoMock, :apply_member_roles, fn "srv-1",
                                                              "user-1",
                                                              ["role-1"],
                                                              @t1 ->
        {:ok, :applied}
      end)

      event = %ChannelEvent.MemberRolesUpdated{
        event_id: "r3",
        occurred_at: @t1,
        server_id: "srv-1",
        user_id: "user-1",
        role_ids: ["role-1"]
      }

      assert :ok = Lifecycle.handle(event)
    end

    test "the overrides of a channel replace the ones we had" do
      expect_alive()
      overrides = [%{role_id: "role-1", allow: [], deny: ["VIEW_CHANNELS"]}]

      expect(Messaging.Chat.RepoMock, :apply_channel_overrides, fn "srv-1",
                                                                   "c-1",
                                                                   ^overrides,
                                                                   @t1 ->
        {:ok, :applied}
      end)

      event = %ChannelEvent.ChannelOverridesUpdated{
        event_id: "r4",
        occurred_at: @t1,
        server_id: "srv-1",
        channel_id: "c-1",
        overrides: overrides
      }

      assert :ok = Lifecycle.handle(event)
    end

    test "the owner of a server is stored" do
      expect_alive()

      expect(Messaging.Chat.RepoMock, :apply_server_owner, fn "srv-1", "user-9", @t1 ->
        {:ok, :applied}
      end)

      event = %ChannelEvent.OwnerUpdated{
        event_id: "r5",
        occurred_at: @t1,
        server_id: "srv-1",
        owner_id: "user-9"
      }

      assert :ok = Lifecycle.handle(event)
    end

    test "the banned words of a server replace the ones we had" do
      expect_alive()

      expect(Messaging.Chat.RepoMock, :apply_word_filter, fn "srv-1", ["tonto"], @t1 ->
        {:ok, :applied}
      end)

      event = %ChannelEvent.WordFilterUpdated{
        event_id: "w1",
        occurred_at: @t1,
        server_id: "srv-1",
        words: ["tonto"]
      }

      assert :ok = Lifecycle.handle(event)
    end

    test "an older banned words list never replaces a newer one" do
      expect_alive()
      expect(Messaging.Chat.RepoMock, :apply_word_filter, fn _s, _w, _a -> {:ok, :stale} end)

      event = %ChannelEvent.WordFilterUpdated{
        event_id: "w2",
        occurred_at: @t1,
        server_id: "srv-1",
        words: []
      }

      assert {:ignored, :stale} = Lifecycle.handle(event)
    end

    test "a snapshot older than the one we have is ignored" do
      expect_alive()
      expect(Messaging.Chat.RepoMock, :apply_server_owner, fn _s, _o, _a -> {:ok, :stale} end)

      event = %ChannelEvent.OwnerUpdated{
        event_id: "r6",
        occurred_at: @t1,
        server_id: "srv-1",
        owner_id: "user-9"
      }

      assert {:ignored, :stale} = Lifecycle.handle(event)
    end

    test "a snapshot of a server that was deleted is ignored and nothing is written" do
      expect(Messaging.Chat.RepoMock, :get_clock, fn "server:srv-1" -> %{"state" => "deleted"} end)

      event = %ChannelEvent.MemberRolesUpdated{
        event_id: "r7",
        occurred_at: @t1,
        server_id: "srv-1",
        user_id: "user-1",
        role_ids: []
      }

      assert {:ignored, :server_deleted} = Lifecycle.handle(event)
    end

    test "a failing write is returned so the event is retried" do
      expect_alive()

      expect(Messaging.Chat.RepoMock, :apply_role, fn _s, _r, _p, _e, _a -> {:error, :timeout} end)

      event = %ChannelEvent.RoleUpdated{
        event_id: "r8",
        occurred_at: @t1,
        server_id: "srv-1",
        role_id: "role-1",
        permissions: [],
        is_everyone: true
      }

      assert {:error, :timeout} = Lifecycle.handle(event)
    end
  end

  describe "profile_updated" do
    defp profile(version),
      do: %ChannelEvent.ProfileUpdated{
        event_id: "p1",
        occurred_at: @t1,
        user_id: "user-1",
        version: version
      }

    test "a newer version is stored" do
      expect(Messaging.Chat.RepoMock, :apply_profile, fn "user-1", 2 -> {:ok, :applied} end)

      assert :ok = Lifecycle.handle(profile(2))
    end

    test "a repeated or older version is ignored" do
      expect(Messaging.Chat.RepoMock, :apply_profile, fn "user-1", 1 -> {:ok, :stale} end)

      assert {:ignored, :stale} = Lifecycle.handle(profile(1))
    end

    test "a failing write is returned so the event is retried" do
      expect(Messaging.Chat.RepoMock, :apply_profile, fn _id, _v -> {:error, :timeout} end)

      assert {:error, :timeout} = Lifecycle.handle(profile(1))
    end
  end

  describe "channel_access_revoked" do
    defp access_revoked,
      do: %ChannelEvent.ChannelAccessRevoked{
        event_id: "e4",
        occurred_at: @t1,
        server_id: "srv-1",
        channel_id: "c-1",
        user_ids: ["user-1", "user-2"]
      }

    test "each listed user is cut from that channel, without touching the clock" do
      MessagingWeb.Endpoint.subscribe("channel:c-1")

      assert :ok = Lifecycle.handle(access_revoked())

      for user <- ["user-1", "user-2"] do
        assert_receive %Phoenix.Socket.Broadcast{
          topic: "channel:c-1",
          event: "access_revoked",
          payload: %{"user_id" => ^user, "reason" => "permissions_changed", "channel_id" => "c-1"}
        }
      end
    end

    test "a duplicate is applied again: it only costs a reconnect" do
      MessagingWeb.Endpoint.subscribe("channel:c-1")

      assert :ok = Lifecycle.handle(access_revoked())
      assert :ok = Lifecycle.handle(access_revoked())

      for _n <- 1..4, do: assert_receive(%Phoenix.Socket.Broadcast{event: "access_revoked"})
    end

    test "if the sockets cannot be told, the error is returned so the event is retried" do
      previous = Application.get_env(:messaging, :broadcaster)
      Application.put_env(:messaging, :broadcaster, Messaging.FailingBroadcaster)
      on_exit(fn -> Application.put_env(:messaging, :broadcaster, previous) end)

      assert {:error, :not_connected} = Lifecycle.handle(access_revoked())
    end
  end
end
