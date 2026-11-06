defmodule Messaging.Events.AdminEventsConsumerServerTest do
  @moduledoc """
  The `admin.server_suspended` / `admin.server_reactivated` side of the consumer,
  with the repo mocked. Whatever cannot be verified must not change any state.
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Mox

  alias Messaging.Events.AdminEventsConsumer
  alias Messaging.Suspension.Signature

  @secret "shared-secret"
  @suspended "admin.server_suspended"
  @reactivated "admin.server_reactivated"
  @occurred_at "2026-10-15T12:00:00.5Z"

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    {:ok, server: Messaging.UUID.generate()}
  end

  test "binds the two user events and the two server events, and not the deletion request" do
    assert AdminEventsConsumer.routing_keys() == [
             "admin.user_suspended",
             "admin.user_reactivated",
             "admin.server_suspended",
             "admin.server_reactivated"
           ]
  end

  describe "a signed suspension" do
    test "is stored and cuts the sockets of every channel of the server", %{server: server} do
      for id <- ["c-1", "c-2"], do: MessagingWeb.Endpoint.subscribe("channel:" <> id)

      expect(Messaging.Chat.RepoMock, :apply_server_suspension, fn ^server, true, 3 ->
        {:ok, :applied}
      end)

      expect(Messaging.Chat.RepoMock, :list_channel_ids, fn ^server -> {:ok, ["c-1", "c-2"]} end)
      expect(Messaging.Chat.RepoMock, :list_members, fn ^server -> {:ok, []} end)

      assert :ack = process(@suspended, server, 3)

      for id <- ["c-1", "c-2"] do
        assert_receive %Phoenix.Socket.Broadcast{
          topic: "channel:" <> ^id,
          event: "access_revoked",
          payload: %{"reason" => "server_suspended", "user_id" => nil}
        }
      end
    end

    test "of a server with no channels in the cache is stored and cuts nothing", %{
      server: server
    } do
      expect(Messaging.Chat.RepoMock, :apply_server_suspension, fn ^server, true, 1 ->
        {:ok, :applied}
      end)

      expect(Messaging.Chat.RepoMock, :list_channel_ids, fn ^server -> {:ok, []} end)
      expect(Messaging.Chat.RepoMock, :list_members, fn ^server -> {:ok, []} end)

      assert :ack = process(@suspended, server, 1)
    end

    test "is acknowledged even if the channels cannot be listed, as the state is stored", %{
      server: server
    } do
      expect(Messaging.Chat.RepoMock, :apply_server_suspension, fn ^server, true, 2 ->
        {:ok, :applied}
      end)

      expect(Messaging.Chat.RepoMock, :list_channel_ids, fn ^server -> {:error, :timeout} end)
      expect(Messaging.Chat.RepoMock, :list_members, fn ^server -> {:ok, []} end)

      log =
        capture_log([level: :warning], fn ->
          assert :ack = process(@suspended, server, 2)
        end)

      assert log =~ "admin_events_consumer_close_sockets_failed"
    end
  end

  describe "a signed reactivation" do
    test "is stored and cuts nothing", %{server: server} do
      MessagingWeb.Endpoint.subscribe("channel:c-1")

      expect(Messaging.Chat.RepoMock, :apply_server_suspension, fn ^server, false, 4 ->
        {:ok, :applied}
      end)

      expect(Messaging.Chat.RepoMock, :list_members, fn ^server -> {:ok, []} end)

      assert :ack = process(@reactivated, server, 4)
      refute_receive %Phoenix.Socket.Broadcast{}, 50
    end
  end

  describe "the members' personal rooms" do
    test "a suspension tells every member, wherever they are", %{server: server} do
      for id <- ["u-1", "u-2"], do: MessagingWeb.Endpoint.subscribe("user:" <> id)

      expect(Messaging.Chat.RepoMock, :apply_server_suspension, fn ^server, true, 3 ->
        {:ok, :applied}
      end)

      expect(Messaging.Chat.RepoMock, :list_channel_ids, fn ^server -> {:ok, []} end)

      expect(Messaging.Chat.RepoMock, :list_members, fn ^server ->
        {:ok, [%{"user_id" => "u-1"}, %{"user_id" => "u-2"}]}
      end)

      assert :ack = process(@suspended, server, 3)

      for id <- ["u-1", "u-2"] do
        assert_receive %Phoenix.Socket.Broadcast{
          topic: "user:" <> ^id,
          event: "server_suspended",
          payload: %{"server_id" => ^server}
        }
      end
    end

    test "a reactivation tells every member", %{server: server} do
      MessagingWeb.Endpoint.subscribe("user:u-1")

      expect(Messaging.Chat.RepoMock, :apply_server_suspension, fn ^server, false, 4 ->
        {:ok, :applied}
      end)

      expect(Messaging.Chat.RepoMock, :list_members, fn ^server ->
        {:ok, [%{"user_id" => "u-1"}]}
      end)

      assert :ack = process(@reactivated, server, 4)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "user:u-1",
        event: "server_reactivated",
        payload: %{"server_id" => ^server}
      }
    end

    test "is acknowledged even if the members cannot be listed, as the state is stored", %{
      server: server
    } do
      expect(Messaging.Chat.RepoMock, :apply_server_suspension, fn ^server, true, 2 ->
        {:ok, :applied}
      end)

      expect(Messaging.Chat.RepoMock, :list_channel_ids, fn ^server -> {:ok, []} end)
      expect(Messaging.Chat.RepoMock, :list_members, fn ^server -> {:error, :timeout} end)

      log =
        capture_log([level: :warning], fn ->
          assert :ack = process(@suspended, server, 2)
        end)

      assert log =~ "admin_events_consumer_notify_members_failed"
    end

    test "a stale event tells nobody", %{server: server} do
      MessagingWeb.Endpoint.subscribe("user:u-1")

      expect(Messaging.Chat.RepoMock, :apply_server_suspension, fn ^server, true, 2 ->
        {:ok, :stale}
      end)

      assert :ack = process(@suspended, server, 2)
      refute_receive %Phoenix.Socket.Broadcast{}, 50
    end
  end

  describe "a stale or repeated event" do
    test "is acknowledged and cuts nothing", %{server: server} do
      MessagingWeb.Endpoint.subscribe("channel:c-1")

      expect(Messaging.Chat.RepoMock, :apply_server_suspension, fn ^server, true, 2 ->
        {:ok, :stale}
      end)

      assert :ack = process(@suspended, server, 2)
      refute_receive %Phoenix.Socket.Broadcast{}, 50
    end
  end

  describe "a failure in Mongo" do
    test "asks for the delivery to be requeued", %{server: server} do
      expect(Messaging.Chat.RepoMock, :apply_server_suspension, fn ^server, true, 3 ->
        {:error, :not_connected}
      end)

      log =
        capture_log([level: :error], fn ->
          assert :retry = process(@suspended, server, 3)
        end)

      assert log =~ "admin_events_consumer_event_failed"
    end
  end

  describe "an event that cannot be trusted" do
    # No expectation on RepoMock: Mox fails the test if the state is touched.
    test "without signature is discarded", %{server: server} do
      body = server |> signed_map(@suspended, 1) |> Map.delete("signature") |> Jason.encode!()
      assert :ack = AdminEventsConsumer.process(body, @suspended, @secret)
    end

    test "with an invalid or malformed signature is discarded", %{server: server} do
      for bad <- ["deadbeef", "not-hex", ""] do
        body = server |> signed_map(@suspended, 1) |> Map.put("signature", bad) |> Jason.encode!()
        assert :ack = AdminEventsConsumer.process(body, @suspended, @secret)
      end
    end

    test "signed with another secret is discarded", %{server: server} do
      body = server |> signed_map(@suspended, 1, "another-secret") |> Jason.encode!()
      assert :ack = AdminEventsConsumer.process(body, @suspended, @secret)
    end

    test "tampered after signing is discarded", %{server: server} do
      body = server |> signed_map(@suspended, 1) |> Map.put("version", 99) |> Jason.encode!()
      assert :ack = AdminEventsConsumer.process(body, @suspended, @secret)

      body =
        server
        |> signed_map(@suspended, 1)
        |> Map.put("server_id", Messaging.UUID.generate())
        |> Jason.encode!()

      assert :ack = AdminEventsConsumer.process(body, @suspended, @secret)
    end

    test "a suspension replayed as a reactivation is discarded", %{server: server} do
      body = server |> signed_map(@suspended, 1) |> Jason.encode!()
      assert :ack = AdminEventsConsumer.process(body, @reactivated, @secret)
    end

    test "an account event with the server routing key is discarded" do
      body =
        Messaging.UUID.generate()
        |> user_signed_map("admin.user_suspended", 1)
        |> Jason.encode!()

      assert :ack = AdminEventsConsumer.process(body, @suspended, @secret)
    end

    test "a server event under a user routing key is discarded", %{server: server} do
      body = server |> signed_map(@suspended, 1) |> Jason.encode!()
      assert :ack = AdminEventsConsumer.process(body, "admin.user_suspended", @secret)
    end

    test "with an empty server_id, a version below 1 or a non integer one is discarded", %{
      server: server
    } do
      for {key, value} <- [{"server_id", ""}, {"version", 0}, {"version", -2}, {"version", "3"}] do
        body = server |> signed_map(@suspended, 1) |> Map.put(key, value) |> Jason.encode!()
        assert :ack = AdminEventsConsumer.process(body, @suspended, @secret)
      end
    end

    test "without server_id is discarded", %{server: server} do
      body = server |> signed_map(@suspended, 1) |> Map.delete("server_id") |> Jason.encode!()
      assert :ack = AdminEventsConsumer.process(body, @suspended, @secret)
    end

    test "that is not JSON, or not an object, is discarded" do
      assert :ack = AdminEventsConsumer.process("{not json", @suspended, @secret)
      assert :ack = AdminEventsConsumer.process("[1, 2]", @suspended, @secret)
    end

    test "with an empty secret in the consumer is discarded", %{server: server} do
      body = server |> signed_map(@suspended, 1, "") |> Jason.encode!()
      assert :ack = AdminEventsConsumer.process(body, @suspended, "")
    end

    test "the deletion request is not consumed here", %{server: server} do
      body =
        server |> signed_map("admin.server_deletion_requested", 1) |> Jason.encode!()

      assert :ack = AdminEventsConsumer.process(body, "admin.server_deletion_requested", @secret)
    end
  end

  defp process(routing_key, server, version) do
    server
    |> signed_map(routing_key, version)
    |> Jason.encode!()
    |> AdminEventsConsumer.process(routing_key, @secret)
  end

  defp signed_map(server, routing_key, version, secret \\ @secret) do
    event = %{
      routing_key: routing_key,
      event_id: Messaging.UUID.generate(),
      server_id: server,
      version: version,
      occurred_at: @occurred_at
    }

    %{
      "event_id" => event.event_id,
      "occurred_at" => @occurred_at,
      "server_id" => server,
      "version" => version,
      "signature" => Signature.sign(event, secret)
    }
  end

  defp user_signed_map(user, routing_key, version) do
    event = %{
      routing_key: routing_key,
      event_id: Messaging.UUID.generate(),
      user_id: user,
      version: version,
      occurred_at: @occurred_at
    }

    %{
      "event_id" => event.event_id,
      "occurred_at" => @occurred_at,
      "user_id" => user,
      "version" => version,
      "signature" => Signature.sign(event, @secret)
    }
  end
end
