mongo_url = System.get_env("MONGO_URL")

if mongo_url do
  defmodule Messaging.Chat.Repo.ReplicaMongoTest do
    use ExUnit.Case, async: false

    alias Messaging.Chat.{ChannelCache, Mentions}
    alias Messaging.Chat.MentionResolver.Replica, as: MentionReplica
    alias Messaging.Chat.PermissionsStore.Replica, as: PermissionsReplica
    alias Messaging.Chat.Repo.Mongo, as: Repo
    alias Messaging.Events.{ChannelEvent, Lifecycle}

    @t1 ~U[2026-10-09 12:00:00.000Z]
    @t2 ~U[2026-10-09 12:00:01.000Z]
    @t3 ~U[2026-10-09 12:00:02.000Z]

    setup do
      previous = Application.get_env(:messaging, :chat_repo)
      Application.put_env(:messaging, :chat_repo, Repo)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:messaging, :chat_repo, previous),
          else: Application.delete_env(:messaging, :chat_repo)
      end)

      for collection <-
            ~w(replica_servers replica_roles replica_members replica_overrides replica_users replica_word_filters) do
        {:ok, _result} = Mongo.delete_many(Messaging.Mongo, collection, %{})
      end

      id = Messaging.UUID.generate()
      {:ok, server: "srv-" <> id, channel: "chan-" <> id}
    end

    describe "banned words" do
      test "a server without a list has an empty one", %{server: server} do
        assert {:ok, []} = Repo.get_word_filter(server)
      end

      test "the newest list wins, an older one is ignored and an empty one clears it",
           %{server: server} do
        assert {:ok, :applied} = Repo.apply_word_filter(server, ["tonto", "feo"], @t2)
        assert {:ok, :stale} = Repo.apply_word_filter(server, ["viejo"], @t1)
        assert {:ok, ["tonto", "feo"]} = Repo.get_word_filter(server)

        assert {:ok, :applied} = Repo.apply_word_filter(server, [], @t3)
        assert {:ok, []} = Repo.get_word_filter(server)
      end

      test "the event goes all the way to blocking a message", %{server: server} do
        event = %ChannelEvent.WordFilterUpdated{
          event_id: "w1",
          occurred_at: @t1,
          server_id: server,
          words: ["no sirve"]
        }

        assert :ok = Lifecycle.handle(event)
        assert {:ok, words} = Repo.get_word_filter(server)
        assert Messaging.Chat.WordFilter.matches("esto NO sirve", words) == ["no sirve"]
      end

      test "deleting the server deletes its list", %{server: server, channel: channel} do
        {:ok, :applied} = Repo.apply_word_filter(server, ["tonto"], @t1)
        assert :ok = Repo.delete_server_data(server, [channel])
        assert {:ok, []} = Repo.get_word_filter(server)
      end
    end

    describe "roles" do
      test "a newer snapshot replaces the role, an older one is ignored", %{server: server} do
        assert {:ok, :applied} = Repo.apply_role(server, "r1", ["VIEW_CHANNELS"], false, @t2)
        assert {:ok, :stale} = Repo.apply_role(server, "r1", ["SEND_MESSAGES"], false, @t1)
        assert {:ok, :applied} = Repo.apply_role(server, "r1", ["SEND_MESSAGES"], false, @t3)

        assert {:ok, [%{"_id" => "r1", "permissions" => ["SEND_MESSAGES"]}]} =
                 Repo.list_roles(server)
      end

      test "a repeated snapshot is harmless", %{server: server} do
        assert {:ok, :applied} = Repo.apply_role(server, "r1", ["VIEW_CHANNELS"], false, @t1)
        assert {:ok, :applied} = Repo.apply_role(server, "r1", ["VIEW_CHANNELS"], false, @t1)

        assert {:ok, [_one]} = Repo.list_roles(server)
      end

      test "a deleted role stays deleted when an older snapshot arrives late", %{server: server} do
        {:ok, :applied} = Repo.apply_role(server, "r1", ["VIEW_CHANNELS"], false, @t1)
        assert {:ok, :applied} = Repo.delete_role(server, "r1", @t2)
        assert {:ok, :stale} = Repo.apply_role(server, "r1", ["VIEW_CHANNELS"], false, @t1)

        assert {:ok, []} = Repo.list_roles(server)
      end

      test "deleting a role takes it off its members and off the channel overrides", %{
        server: server,
        channel: channel
      } do
        {:ok, :applied} = Repo.apply_role(server, "r1", ["VIEW_CHANNELS"], false, @t1)
        {:ok, :applied} = Repo.apply_member_roles(server, "ana", ["r1", "r2"], @t1)

        overrides = [
          %{role_id: "r1", allow: [], deny: ["VIEW_CHANNELS"]},
          %{role_id: "r2", allow: ["SEND_MESSAGES"], deny: []}
        ]

        {:ok, :applied} = Repo.apply_channel_overrides(server, channel, overrides, @t1)

        assert {:ok, :applied} = Repo.delete_role(server, "r1", @t2)

        assert %{"role_ids" => ["r2"]} = Repo.get_member(server, "ana")

        assert {:ok, [%{"role_id" => "r2", "allow" => ["SEND_MESSAGES"], "deny" => []}]} =
                 Repo.get_channel_overrides(channel)
      end
    end

    describe "members" do
      test "the roles of a member are replaced by a newer snapshot only", %{server: server} do
        assert {:ok, :applied} = Repo.apply_member_roles(server, "ana", ["r1"], @t2)
        assert {:ok, :stale} = Repo.apply_member_roles(server, "ana", ["r2"], @t1)
        assert {:ok, :applied} = Repo.apply_member_roles(server, "ana", ["r1", "r2"], @t3)

        assert %{"user_id" => "ana", "role_ids" => ["r1", "r2"]} = Repo.get_member(server, "ana")
      end

      test "a member who left is gone and an older snapshot does not bring them back", %{
        server: server
      } do
        {:ok, :applied} = Repo.apply_member_roles(server, "ana", ["r1"], @t1)
        assert {:ok, :applied} = Repo.delete_member(server, "ana", @t2)
        assert {:ok, :stale} = Repo.apply_member_roles(server, "ana", ["r1"], @t1)

        assert nil == Repo.get_member(server, "ana")
        assert {:ok, []} = Repo.list_members(server)
      end

      test "a member who left and joined again is back", %{server: server} do
        {:ok, :applied} = Repo.apply_member_roles(server, "ana", ["r1"], @t1)
        {:ok, :applied} = Repo.delete_member(server, "ana", @t2)
        assert {:ok, :applied} = Repo.apply_member_roles(server, "ana", ["r1"], @t3)

        assert %{"role_ids" => ["r1"]} = Repo.get_member(server, "ana")
      end

      test "get_members/2 returns only the asked members of that server", %{server: server} do
        {:ok, :applied} = Repo.apply_member_roles(server, "ana", [], @t1)
        {:ok, :applied} = Repo.apply_member_roles(server, "beto", [], @t1)
        {:ok, :applied} = Repo.apply_member_roles("other-" <> server, "ana", [], @t1)

        assert {:ok, [%{"user_id" => "ana"}]} = Repo.get_members(server, ["ana", "ghost"])
        assert {:ok, []} = Repo.get_members(server, [])
        assert {:ok, members} = Repo.list_members(server)
        assert Enum.sort(Enum.map(members, & &1["user_id"])) == ["ana", "beto"]
      end
    end

    describe "channel overrides and owner" do
      test "a channel without overrides has an empty list", %{channel: channel} do
        assert {:ok, []} = Repo.get_channel_overrides(channel)
      end

      test "the newest snapshot of a channel wins, and an empty one clears it", %{
        server: server,
        channel: channel
      } do
        one = [%{role_id: "r1", allow: [], deny: ["VIEW_CHANNELS"]}]

        assert {:ok, :applied} = Repo.apply_channel_overrides(server, channel, one, @t2)
        assert {:ok, :stale} = Repo.apply_channel_overrides(server, channel, [], @t1)
        assert {:ok, [_one]} = Repo.get_channel_overrides(channel)

        assert {:ok, :applied} = Repo.apply_channel_overrides(server, channel, [], @t3)
        assert {:ok, []} = Repo.get_channel_overrides(channel)
      end

      test "the owner follows the newest snapshot", %{server: server} do
        assert nil == Repo.get_server_owner(server)
        assert {:ok, :applied} = Repo.apply_server_owner(server, "ana", @t2)
        assert {:ok, :stale} = Repo.apply_server_owner(server, "beto", @t1)
        assert "ana" == Repo.get_server_owner(server)
        assert {:ok, :applied} = Repo.apply_server_owner(server, "beto", @t3)
        assert "beto" == Repo.get_server_owner(server)
      end
    end

    describe "users" do
      test "a user is known once a profile arrived, and only a higher version replaces it" do
        user = "user-" <> Messaging.UUID.generate()

        assert false == Repo.user_known?(user)
        assert {:ok, :applied} = Repo.apply_profile(user, 2)
        assert true == Repo.user_known?(user)
        assert {:ok, :stale} = Repo.apply_profile(user, 2)
        assert {:ok, :stale} = Repo.apply_profile(user, 1)
        assert {:ok, :applied} = Repo.apply_profile(user, 3)
      end
    end

    describe "cleanup" do
      test "deleting a channel deletes its overrides", %{server: server, channel: channel} do
        :ok = Repo.upsert_channel(%{"_id" => channel, "server_id" => server, "kind" => "text"})

        {:ok, :applied} =
          Repo.apply_channel_overrides(
            server,
            channel,
            [%{role_id: "r1", allow: [], deny: ["VIEW_CHANNELS"]}],
            @t1
          )

        assert :ok = Repo.delete_channel(channel)
        assert {:ok, []} = Repo.get_channel_overrides(channel)
      end

      test "deleting a server deletes everything replicated about it", %{
        server: server,
        channel: channel
      } do
        {:ok, :applied} = Repo.apply_server_owner(server, "ana", @t1)
        {:ok, :applied} = Repo.apply_role(server, "r1", [], false, @t1)
        {:ok, :applied} = Repo.apply_member_roles(server, "ana", ["r1"], @t1)

        {:ok, :applied} =
          Repo.apply_channel_overrides(
            server,
            channel,
            [%{role_id: "r1", allow: [], deny: []}],
            @t1
          )

        assert :ok = Repo.delete_server_data(server, [channel])

        assert nil == Repo.get_server_owner(server)
        assert {:ok, []} = Repo.list_roles(server)
        assert {:ok, []} = Repo.list_members(server)
        assert {:ok, []} = Repo.get_channel_overrides(channel)
      end
    end

    describe "events applied to the real replica" do
      defp text_channel(server, channel),
        do: %ChannelCache{channel_id: channel, server_id: server, name: "general", kind: "text"}

      defp apply_event(event), do: assert(:ok = Lifecycle.handle(event))

      defp role_event(server, id, permissions, is_everyone, at),
        do: %ChannelEvent.RoleUpdated{
          event_id: "e-" <> id,
          occurred_at: at,
          server_id: server,
          role_id: id,
          permissions: permissions,
          is_everyone: is_everyone
        }

      defp member_event(server, user, roles, at),
        do: %ChannelEvent.MemberRolesUpdated{
          event_id: "e-" <> user,
          occurred_at: at,
          server_id: server,
          user_id: user,
          role_ids: roles
        }

      defp overrides_event(server, channel, overrides, at),
        do: %ChannelEvent.ChannelOverridesUpdated{
          event_id: "e-ov",
          occurred_at: at,
          server_id: server,
          channel_id: channel,
          overrides: overrides
        }

      defp seed_server(server, owner \\ "owner-1") do
        apply_event(%ChannelEvent.OwnerUpdated{
          event_id: "e-owner",
          occurred_at: @t1,
          server_id: server,
          owner_id: owner
        })

        apply_event(role_event(server, "everyone", ["VIEW_CHANNELS", "SEND_MESSAGES"], true, @t1))

        apply_event(role_event(server, "mod", ["MANAGE_MESSAGES"], false, @t1))
        apply_event(member_event(server, owner, ["everyone"], @t1))
        apply_event(member_event(server, "ana", ["everyone"], @t1))
        apply_event(member_event(server, "beto", ["everyone", "mod"], @t1))
      end

      test "members get the permissions their roles grant", %{server: server, channel: channel} do
        seed_server(server)
        ch = text_channel(server, channel)

        assert {:ok, true} = PermissionsReplica.can_send_messages?(ch, "ana")
        assert {:ok, false} = PermissionsReplica.can_manage_messages?(ch, "ana")
        assert {:ok, true} = PermissionsReplica.can_manage_messages?(ch, "beto")
        assert {:ok, false} = PermissionsReplica.can_view_channel?(ch, "stranger")
      end

      test "an override that hides the channel takes effect with its event", %{
        server: server,
        channel: channel
      } do
        seed_server(server)
        ch = text_channel(server, channel)
        assert {:ok, true} = PermissionsReplica.can_view_channel?(ch, "ana")

        apply_event(
          overrides_event(
            server,
            channel,
            [%{role_id: "everyone", allow: [], deny: ["VIEW_CHANNELS"]}],
            @t2
          )
        )

        assert {:ok, false} = PermissionsReplica.can_view_channel?(ch, "ana")

        apply_event(overrides_event(server, channel, [], @t3))

        assert {:ok, true} = PermissionsReplica.can_view_channel?(ch, "ana")
      end

      test "taking a permission away from a role is seen by its members", %{
        server: server,
        channel: channel
      } do
        seed_server(server)
        ch = text_channel(server, channel)

        apply_event(role_event(server, "everyone", ["VIEW_CHANNELS"], true, @t2))

        assert {:ok, false} = PermissionsReplica.can_send_messages?(ch, "ana")
      end

      test "a member who left cannot do anything", %{server: server, channel: channel} do
        seed_server(server)

        apply_event(%ChannelEvent.MemberLeft{
          event_id: "e-left",
          occurred_at: @t2,
          server_id: server,
          user_id: "ana"
        })

        assert {:ok, false} =
                 PermissionsReplica.can_view_channel?(text_channel(server, channel), "ana")
      end

      test "an event that arrives late does not undo a newer one", %{
        server: server,
        channel: channel
      } do
        seed_server(server)
        ch = text_channel(server, channel)

        apply_event(role_event(server, "everyone", ["VIEW_CHANNELS"], true, @t3))

        assert {:ignored, :stale} =
                 Lifecycle.handle(
                   role_event(server, "everyone", ["VIEW_CHANNELS", "SEND_MESSAGES"], true, @t2)
                 )

        assert {:ok, false} = PermissionsReplica.can_send_messages?(ch, "ana")
      end

      test "mentions are resolved with the replica", %{server: server, channel: channel} do
        seed_server(server)
        ch = text_channel(server, channel)

        assert {:ok,
                %Mentions{
                  user_ids: ["ana"],
                  role_ids: [],
                  everyone: false,
                  recipient_ids: ["ana"]
                }} =
                 MentionReplica.resolve(
                   ch,
                   %{user_ids: ["ana", "ghost"], role_ids: [], everyone: false},
                   "beto"
                 )

        assert {:ok, %Mentions{everyone: true, recipient_ids: ["ana", "beto"]}} =
                 MentionReplica.resolve(
                   ch,
                   %{user_ids: [], role_ids: [], everyone: true},
                   "owner-1"
                 )
      end
    end
  end
else
  defmodule Messaging.Chat.Repo.ReplicaMongoTest do
    use ExUnit.Case

    test "skipped: set MONGO_URL to run this against a real Mongo instance" do
      IO.puts("\nSkipping replica Mongo test: MONGO_URL not set.\n")
    end
  end
end
