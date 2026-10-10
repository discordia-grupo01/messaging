defmodule Messaging.Events.ChannelEventTest do
  use ExUnit.Case, async: true

  alias Messaging.Events.ChannelEvent

  alias Messaging.Events.ChannelEvent.{
    ChannelAccessRevoked,
    ChannelCreated,
    ChannelDeleted,
    MemberJoined,
    MemberLeft,
    MemberMuted,
    MemberUnmuted,
    ServerDeleted
  }

  describe "parse/2 for servers.channel_created" do
    test "parses a well-formed payload" do
      payload = %{
        "event_id" => "evt-1",
        "occurred_at" => "2026-09-28T12:00:00Z",
        "server_id" => "srv-1",
        "channel_id" => "chan-1",
        "name" => "general",
        "kind" => "text"
      }

      assert {:ok,
              %ChannelCreated{
                channel_id: "chan-1",
                server_id: "srv-1",
                name: "general",
                kind: "text"
              }} = ChannelEvent.parse(ChannelEvent.routing_key_channel_created(), payload)
    end

    test "rejects a payload missing a required field" do
      payload = %{
        "event_id" => "evt-1",
        "occurred_at" => "2026-09-28T12:00:00Z",
        "server_id" => "srv-1"
      }

      assert {:error, :invalid_payload} =
               ChannelEvent.parse(ChannelEvent.routing_key_channel_created(), payload)
    end
  end

  describe "parse/2 for servers.channel_deleted" do
    test "parses a well-formed payload" do
      payload = %{
        "event_id" => "evt-2",
        "occurred_at" => "2026-09-28T12:00:00Z",
        "server_id" => "srv-1",
        "channel_id" => "chan-1"
      }

      assert {:ok, %ChannelDeleted{channel_id: "chan-1", server_id: "srv-1"}} =
               ChannelEvent.parse(ChannelEvent.routing_key_channel_deleted(), payload)
    end

    test "rejects a payload missing a required field" do
      payload = %{"event_id" => "evt-2", "occurred_at" => "2026-09-28T12:00:00Z"}

      assert {:error, :invalid_payload} =
               ChannelEvent.parse(ChannelEvent.routing_key_channel_deleted(), payload)
    end
  end

  test "parse/2 rejects an unknown routing key" do
    assert {:error, :unknown_routing_key} = ChannelEvent.parse("servers.unknown_thing", %{})
  end

  describe "parse/2 for servers.server_deleted" do
    @valid %{
      "event_id" => "evt-3",
      "occurred_at" => "2026-09-28T12:00:00Z",
      "server_id" => "srv-1",
      "channel_ids" => ["chan-1", "chan-2"]
    }

    test "parses a well-formed payload" do
      assert {:ok, %ServerDeleted{server_id: "srv-1", channel_ids: ["chan-1", "chan-2"]}} =
               ChannelEvent.parse(ChannelEvent.routing_key_server_deleted(), @valid)
    end

    test "accepts a server that had no channels" do
      payload = Map.put(@valid, "channel_ids", [])

      assert {:ok, %ServerDeleted{channel_ids: []}} =
               ChannelEvent.parse(ChannelEvent.routing_key_server_deleted(), payload)
    end

    test "rejects a payload without channel_ids" do
      payload = Map.delete(@valid, "channel_ids")

      assert {:error, :invalid_payload} =
               ChannelEvent.parse(ChannelEvent.routing_key_server_deleted(), payload)
    end

    test "rejects channel_ids that is not a list" do
      for bad <- [nil, "chan-1", %{"a" => 1}] do
        payload = Map.put(@valid, "channel_ids", bad)

        assert {:error, :invalid_payload} =
                 ChannelEvent.parse(ChannelEvent.routing_key_server_deleted(), payload)
      end
    end

    test "rejects channel_ids holding something that is not a string id" do
      payload = Map.put(@valid, "channel_ids", ["chan-1", %{"$ne" => "x"}])

      assert {:error, :invalid_payload} =
               ChannelEvent.parse(ChannelEvent.routing_key_server_deleted(), payload)
    end

    test "rejects a payload without server_id" do
      payload = Map.delete(@valid, "server_id")

      assert {:error, :invalid_payload} =
               ChannelEvent.parse(ChannelEvent.routing_key_server_deleted(), payload)
    end
  end

  describe "parse/2 for servers.member_left" do
    @member_left %{
      "event_id" => "evt-ml",
      "occurred_at" => "2026-10-06T12:00:00Z",
      "server_id" => "srv-1",
      "user_id" => "user-1"
    }

    test "parses the payload servers publishes on leave, kick and ban" do
      assert {:ok,
              %MemberLeft{
                event_id: "evt-ml",
                server_id: "srv-1",
                user_id: "user-1"
              }} = ChannelEvent.parse(ChannelEvent.routing_key_member_left(), @member_left)
    end

    test "uses the routing key of events-contract (membership)" do
      assert ChannelEvent.routing_key_member_left() == "servers.member_left"
    end

    for field <- ["server_id", "user_id", "event_id"] do
      test "rejects a payload without #{field}" do
        payload = Map.delete(@member_left, unquote(field))

        assert {:error, :invalid_payload} =
                 ChannelEvent.parse(ChannelEvent.routing_key_member_left(), payload)
      end
    end

    test "rejects ids that are not strings, so they can't become Mongo operators" do
      payload = Map.put(@member_left, "user_id", %{"$ne" => "x"})

      assert {:error, :invalid_payload} =
               ChannelEvent.parse(ChannelEvent.routing_key_member_left(), payload)
    end
  end

  describe "parse/2 for servers.channel_access_revoked" do
    @access_revoked %{
      "event_id" => "evt-car",
      "occurred_at" => "2026-10-08T12:00:00Z",
      "server_id" => "srv-1",
      "channel_id" => "c-1",
      "user_ids" => ["user-1", "user-2"]
    }

    test "parses the users who lost access to one channel" do
      assert {:ok,
              %ChannelAccessRevoked{
                event_id: "evt-car",
                occurred_at: ~U[2026-10-08 12:00:00Z],
                server_id: "srv-1",
                channel_id: "c-1",
                user_ids: ["user-1", "user-2"]
              }} =
               ChannelEvent.parse(
                 ChannelEvent.routing_key_channel_access_revoked(),
                 @access_revoked
               )
    end

    test "uses the routing key of events-contract (channels)" do
      assert ChannelEvent.routing_key_channel_access_revoked() ==
               "servers.channel_access_revoked"
    end

    test "a user listed twice is told once" do
      payload = Map.put(@access_revoked, "user_ids", ["user-1", "user-1", "user-2"])

      assert {:ok, %ChannelAccessRevoked{user_ids: ["user-1", "user-2"]}} =
               ChannelEvent.parse(ChannelEvent.routing_key_channel_access_revoked(), payload)
    end

    for field <- ["event_id", "server_id", "channel_id", "user_ids"] do
      test "rejects a payload without #{field}" do
        payload = Map.delete(@access_revoked, unquote(field))

        assert {:error, :invalid_payload} =
                 ChannelEvent.parse(ChannelEvent.routing_key_channel_access_revoked(), payload)
      end
    end

    test "rejects empty or non-string ids and an empty or malformed user list" do
      bad_payloads = [
        Map.put(@access_revoked, "event_id", ""),
        Map.put(@access_revoked, "server_id", 1),
        Map.put(@access_revoked, "channel_id", %{"$ne" => "x"}),
        Map.put(@access_revoked, "user_ids", []),
        Map.put(@access_revoked, "user_ids", "user-1"),
        Map.put(@access_revoked, "user_ids", ["user-1", ""]),
        Map.put(@access_revoked, "user_ids", ["user-1", nil]),
        Map.put(@access_revoked, "occurred_at", "ayer")
      ]

      for bad <- bad_payloads do
        assert {:error, :invalid_payload} =
                 ChannelEvent.parse(ChannelEvent.routing_key_channel_access_revoked(), bad)
      end
    end
  end

  describe "parse/2 for servers.member_joined" do
    @joined %{
      "event_id" => "evt-1",
      "occurred_at" => "2026-09-28T12:00:00Z",
      "server_id" => "srv-1",
      "user_id" => "user-1"
    }

    test "parses a well-formed payload" do
      assert {:ok, %MemberJoined{server_id: "srv-1", user_id: "user-1"}} =
               ChannelEvent.parse(ChannelEvent.routing_key_member_joined(), @joined)
    end

    test "rejects a payload without user_id or with ids that are not strings" do
      for bad <- [Map.delete(@joined, "user_id"), Map.put(@joined, "user_id", %{"$ne" => 1})] do
        assert {:error, :invalid_payload} =
                 ChannelEvent.parse(ChannelEvent.routing_key_member_joined(), bad)
      end
    end
  end

  describe "parse/2 for servers.member_muted" do
    @muted %{
      "event_id" => "evt-muted",
      "occurred_at" => "2026-10-06T12:00:00Z",
      "server_id" => "srv-1",
      "user_id" => "user-1",
      "muted_by" => "user-2",
      "until_at" => "2026-10-07T12:00:00Z",
      "reason" => "spam"
    }

    test "parses a well-formed mute event" do
      assert {:ok,
              %MemberMuted{
                event_id: "evt-muted",
                server_id: "srv-1",
                user_id: "user-1",
                muted_by: "user-2",
                until_at: ~U[2026-10-07 12:00:00Z],
                reason: "spam"
              }} = ChannelEvent.parse(ChannelEvent.routing_key_member_muted(), @muted)
    end

    test "rejects missing fields" do
      for bad <- [
            Map.delete(@muted, "muted_by"),
            Map.delete(@muted, "until_at"),
            Map.delete(@muted, "reason")
          ] do
        assert {:error, :invalid_payload} =
                 ChannelEvent.parse(ChannelEvent.routing_key_member_muted(), bad)
      end
    end
  end

  describe "parse/2 for servers.word_filter_updated" do
    @word_filter %{
      "event_id" => "evt-words",
      "occurred_at" => "2026-10-10T18:00:00Z",
      "server_id" => "srv-1",
      "words" => ["tonto", "no sirve"]
    }

    test "parses the whole list, and an empty one" do
      assert {:ok,
              %ChannelEvent.WordFilterUpdated{
                event_id: "evt-words",
                occurred_at: ~U[2026-10-10 18:00:00Z],
                server_id: "srv-1",
                words: ["tonto", "no sirve"]
              }} =
               ChannelEvent.parse(ChannelEvent.routing_key_word_filter_updated(), @word_filter)

      assert {:ok, %ChannelEvent.WordFilterUpdated{words: []}} =
               ChannelEvent.parse(
                 ChannelEvent.routing_key_word_filter_updated(),
                 Map.put(@word_filter, "words", [])
               )
    end

    test "rejects a missing list, null, or words that are not strings" do
      for bad <- [
            Map.delete(@word_filter, "words"),
            Map.put(@word_filter, "words", nil),
            Map.put(@word_filter, "words", ["ok", 1]),
            Map.put(@word_filter, "server_id", 7)
          ] do
        assert {:error, :invalid_payload} =
                 ChannelEvent.parse(ChannelEvent.routing_key_word_filter_updated(), bad)
      end
    end
  end

  describe "parse/2 for servers.member_unmuted" do
    @unmuted %{
      "event_id" => "evt-unmuted",
      "occurred_at" => "2026-10-06T13:00:00Z",
      "server_id" => "srv-1",
      "user_id" => "user-1",
      "unmuted_by" => "user-2",
      "reason" => "expired"
    }

    test "parses a well-formed unmute event" do
      assert {:ok,
              %MemberUnmuted{
                event_id: "evt-unmuted",
                server_id: "srv-1",
                user_id: "user-1",
                unmuted_by: "user-2",
                reason: "expired"
              }} = ChannelEvent.parse(ChannelEvent.routing_key_member_unmuted(), @unmuted)
    end

    test "rejects missing fields" do
      for bad <- [Map.delete(@unmuted, "unmuted_by"), Map.delete(@unmuted, "reason")] do
        assert {:error, :invalid_payload} =
                 ChannelEvent.parse(ChannelEvent.routing_key_member_unmuted(), bad)
      end
    end
  end

  describe "parse/2 for servers.role_updated" do
    @role_updated %{
      "event_id" => "evt-r1",
      "occurred_at" => "2026-10-09T12:00:00.123456Z",
      "server_id" => "srv-1",
      "role_id" => "role-1",
      "permissions" => ["SEND_MESSAGES", "VIEW_CHANNELS"],
      "is_everyone" => false
    }

    test "parses the snapshot of a role" do
      assert {:ok,
              %ChannelEvent.RoleUpdated{
                server_id: "srv-1",
                role_id: "role-1",
                permissions: ["SEND_MESSAGES", "VIEW_CHANNELS"],
                is_everyone: false
              }} = ChannelEvent.parse(ChannelEvent.routing_key_role_updated(), @role_updated)
    end

    test "a role may have no permissions" do
      assert {:ok, %ChannelEvent.RoleUpdated{permissions: []}} =
               ChannelEvent.parse(
                 ChannelEvent.routing_key_role_updated(),
                 %{@role_updated | "permissions" => []}
               )
    end

    for field <- ~w(server_id role_id permissions is_everyone) do
      test "rejects a payload without #{field}" do
        assert {:error, :invalid_payload} =
                 ChannelEvent.parse(
                   ChannelEvent.routing_key_role_updated(),
                   Map.delete(@role_updated, unquote(field))
                 )
      end
    end

    test "rejects permissions that are not a list of names" do
      for bad <- ["VIEW_CHANNELS", [1, 2], nil] do
        assert {:error, :invalid_payload} =
                 ChannelEvent.parse(
                   ChannelEvent.routing_key_role_updated(),
                   %{@role_updated | "permissions" => bad}
                 )
      end
    end
  end

  describe "parse/2 for servers.role_deleted" do
    test "parses a well-formed payload and rejects an incomplete one" do
      payload = %{
        "event_id" => "evt-r2",
        "occurred_at" => "2026-10-09T12:00:00Z",
        "server_id" => "srv-1",
        "role_id" => "role-1"
      }

      assert {:ok, %ChannelEvent.RoleDeleted{server_id: "srv-1", role_id: "role-1"}} =
               ChannelEvent.parse(ChannelEvent.routing_key_role_deleted(), payload)

      assert {:error, :invalid_payload} =
               ChannelEvent.parse(
                 ChannelEvent.routing_key_role_deleted(),
                 Map.delete(payload, "role_id")
               )
    end
  end

  describe "parse/2 for servers.member_roles_updated" do
    @member_roles %{
      "event_id" => "evt-m1",
      "occurred_at" => "2026-10-09T12:00:00Z",
      "server_id" => "srv-1",
      "user_id" => "user-1",
      "role_ids" => ["role-1", "role-2", "role-1"]
    }

    test "parses the roles of a member without repeats" do
      assert {:ok,
              %ChannelEvent.MemberRolesUpdated{user_id: "user-1", role_ids: ["role-1", "role-2"]}} =
               ChannelEvent.parse(ChannelEvent.routing_key_member_roles_updated(), @member_roles)
    end

    test "a member may have no roles" do
      assert {:ok, %ChannelEvent.MemberRolesUpdated{role_ids: []}} =
               ChannelEvent.parse(
                 ChannelEvent.routing_key_member_roles_updated(),
                 %{@member_roles | "role_ids" => []}
               )
    end

    test "rejects missing fields and role ids that are not strings" do
      for bad <- [Map.delete(@member_roles, "user_id"), %{@member_roles | "role_ids" => [%{}]}] do
        assert {:error, :invalid_payload} =
                 ChannelEvent.parse(ChannelEvent.routing_key_member_roles_updated(), bad)
      end
    end
  end

  describe "parse/2 for servers.channel_overrides_updated" do
    @overrides %{
      "event_id" => "evt-o1",
      "occurred_at" => "2026-10-09T12:00:00Z",
      "server_id" => "srv-1",
      "channel_id" => "chan-1",
      "overrides" => [
        %{"role_id" => "role-1", "allow" => ["SEND_MESSAGES"], "deny" => []},
        %{"role_id" => "role-2", "allow" => [], "deny" => ["VIEW_CHANNELS"]}
      ]
    }

    test "parses every override of the channel, in order" do
      assert {:ok,
              %ChannelEvent.ChannelOverridesUpdated{
                channel_id: "chan-1",
                overrides: [
                  %{role_id: "role-1", allow: ["SEND_MESSAGES"], deny: []},
                  %{role_id: "role-2", allow: [], deny: ["VIEW_CHANNELS"]}
                ]
              }} =
               ChannelEvent.parse(
                 ChannelEvent.routing_key_channel_overrides_updated(),
                 @overrides
               )
    end

    test "an empty list means the channel has no overrides left" do
      assert {:ok, %ChannelEvent.ChannelOverridesUpdated{overrides: []}} =
               ChannelEvent.parse(
                 ChannelEvent.routing_key_channel_overrides_updated(),
                 %{@overrides | "overrides" => []}
               )
    end

    test "rejects a malformed override list" do
      bad_lists = [
        nil,
        "x",
        [%{"role_id" => "role-1", "allow" => []}],
        [%{"role_id" => "", "allow" => [], "deny" => []}],
        [%{"role_id" => "role-1", "allow" => "SEND_MESSAGES", "deny" => []}]
      ]

      for bad <- bad_lists do
        assert {:error, :invalid_payload} =
                 ChannelEvent.parse(
                   ChannelEvent.routing_key_channel_overrides_updated(),
                   %{@overrides | "overrides" => bad}
                 )
      end
    end
  end

  describe "parse/2 for servers.owner_updated" do
    test "parses a well-formed payload and rejects an incomplete one" do
      payload = %{
        "event_id" => "evt-w1",
        "occurred_at" => "2026-10-09T12:00:00Z",
        "server_id" => "srv-1",
        "owner_id" => "user-1"
      }

      assert {:ok, %ChannelEvent.OwnerUpdated{server_id: "srv-1", owner_id: "user-1"}} =
               ChannelEvent.parse(ChannelEvent.routing_key_owner_updated(), payload)

      assert {:error, :invalid_payload} =
               ChannelEvent.parse(
                 ChannelEvent.routing_key_owner_updated(),
                 %{payload | "owner_id" => ""}
               )
    end
  end

  describe "parse/2 for users.profile_updated" do
    @profile %{
      "event_id" => "evt-p1",
      "occurred_at" => "2026-10-09T12:00:00Z",
      "user_id" => "user-1",
      "version" => 3,
      "name" => "Ana",
      "avatar_url" => "",
      "description" => "",
      "status_text" => "",
      "status_emoji" => ""
    }

    test "keeps only the id and the version of the snapshot" do
      assert {:ok, %ChannelEvent.ProfileUpdated{user_id: "user-1", version: 3} = event} =
               ChannelEvent.parse(ChannelEvent.routing_key_profile_updated(), @profile)

      refute Map.has_key?(event, :name)
    end

    test "rejects a missing user, a missing version or a version that is not positive" do
      for bad <- [
            Map.delete(@profile, "user_id"),
            Map.delete(@profile, "version"),
            %{@profile | "version" => 0},
            %{@profile | "version" => "3"}
          ] do
        assert {:error, :invalid_payload} =
                 ChannelEvent.parse(ChannelEvent.routing_key_profile_updated(), bad)
      end
    end
  end

  describe "occurred_at" do
    test "is parsed into a DateTime, so events can be ordered" do
      payload = %{
        "event_id" => "evt-1",
        "occurred_at" => "2026-09-28T12:00:00.250Z",
        "server_id" => "srv-1",
        "user_id" => "user-1"
      }

      assert {:ok, %MemberLeft{occurred_at: at}} =
               ChannelEvent.parse(ChannelEvent.routing_key_member_left(), payload)

      assert at == ~U[2026-09-28 12:00:00.250Z]
    end

    test "a timestamp that does not parse makes the whole event invalid, for every event type" do
      base = %{"event_id" => "e", "server_id" => "s", "user_id" => "u"}

      cases = [
        {ChannelEvent.routing_key_member_left(), base},
        {ChannelEvent.routing_key_member_joined(), base},
        {ChannelEvent.routing_key_channel_deleted(),
         %{"event_id" => "e", "server_id" => "s", "channel_id" => "c"}},
        {ChannelEvent.routing_key_server_deleted(),
         %{"event_id" => "e", "server_id" => "s", "channel_ids" => []}},
        {ChannelEvent.routing_key_channel_created(),
         %{
           "event_id" => "e",
           "server_id" => "s",
           "channel_id" => "c",
           "name" => "n",
           "kind" => "text"
         }}
      ]

      for {key, payload} <- cases, bad <- ["ayer", "", 12_345, nil] do
        assert {:error, :invalid_payload} =
                 ChannelEvent.parse(key, Map.put(payload, "occurred_at", bad))
      end
    end
  end
end
