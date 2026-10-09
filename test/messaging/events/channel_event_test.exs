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
    assert {:error, :unknown_routing_key} = ChannelEvent.parse("servers.role_updated", %{})
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
