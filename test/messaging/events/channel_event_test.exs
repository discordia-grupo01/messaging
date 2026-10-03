defmodule Messaging.Events.ChannelEventTest do
  use ExUnit.Case, async: true

  alias Messaging.Events.ChannelEvent
  alias Messaging.Events.ChannelEvent.{ChannelCreated, ChannelDeleted, ServerDeleted}

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
              }} =
               ChannelEvent.parse(ChannelEvent.routing_key_channel_created(), payload)
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
    assert {:error, :unknown_routing_key} = ChannelEvent.parse("servers.member_joined", %{})
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
end
