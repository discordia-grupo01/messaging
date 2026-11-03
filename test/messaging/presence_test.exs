defmodule Messaging.PresenceTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  import Mox

  alias Messaging.Presence

  setup :verify_on_exit!

  setup do
    test_pid = self()

    stub(Messaging.Outbox.StoreMock, :insert, fn rows ->
      send(test_pid, {:outbox, rows})
      :ok
    end)

    :ok
  end

  @ana "11111111-1111-4111-8111-111111111111"
  @beto "22222222-2222-4222-8222-222222222222"
  @cami "33333333-3333-4333-8333-333333333333"

  defp conn(id, idle \\ false), do: %{"id" => id, "instance" => "i-1", "idle" => idle}

  defp doc(manual, connections, version \\ 4),
    do: %{"_id" => @ana, "manual" => manual, "connections" => connections, "version" => version}

  # Ana is in one server and has a DM with Beto, nobody blocked anybody.
  defp stub_audience(partners \\ [@beto]) do
    stub(Messaging.Presence.StoreMock, :member_server_ids, fn @ana -> {:ok, ["srv-1"]} end)
    stub(Messaging.Presence.StoreMock, :dm_partner_ids, fn @ana, _limit -> {:ok, partners} end)
    stub(Messaging.Chat.RepoMock, :get_blocks, fn _ids -> {:ok, []} end)
  end

  defp capture_publishes do
    test_pid = self()

    stub(Messaging.EventPublisherMock, :publish_event, fn _id, topic, event, payload ->
      send(test_pid, {:published, topic, event, payload})
      :ok
    end)
  end

  defp expect_change(expected_change, result) do
    expect(Messaging.Presence.StoreMock, :change, fn @ana, change ->
      assert change == expected_change
      result
    end)
  end

  describe "connect/3" do
    test "CA1: the first connection makes the user online for servers and DMs" do
      stub_audience()
      capture_publishes()
      expect_change({:connect, "c1", "i-1"}, {:ok, {:changed, doc("online", [], 4)}})

      assert {:ok, "online"} = Presence.connect(@ana, "c1", "i-1")

      payload = %{"user_id" => @ana, "status" => "online", "version" => 5}
      assert_received {:published, "presence:srv-1", "presence_updated", ^payload}
      assert_received {:published, "user:" <> @beto, "presence_updated", ^payload}
    end

    test "a second tab does not notify anyone: the status did not change" do
      expect_change({:connect, "c2", "i-1"}, {:ok, {:changed, doc("online", [conn("c1")])}})

      assert {:ok, "online"} = Presence.connect(@ana, "c2", "i-1")
      refute_received {:published, _, _, _}
    end

    test "returns the status picked by hand, even invisible, and nobody hears of it" do
      expect_change({:connect, "c1", "i-1"}, {:ok, {:changed, doc("invisible", [])}})

      assert {:ok, "invisible"} = Presence.connect(@ana, "c1", "i-1")
      refute_received {:published, _, _, _}
    end

    test "a user never seen starts online" do
      stub_audience([])
      capture_publishes()
      expect_change({:connect, "c1", "i-1"}, {:ok, {:changed, nil}})

      assert {:ok, "online"} = Presence.connect(@ana, "c1", "i-1")

      assert_received {:published, "presence:srv-1", "presence_updated",
                       %{"status" => "online", "version" => 1}}
    end

    test "a store failure is returned and logged" do
      expect_change({:connect, "c1", "i-1"}, {:error, :timeout})

      log = capture_log(fn -> assert {:error, :timeout} = Presence.connect(@ana, "c1", "i-1") end)
      assert log =~ "presence_change_failed"
    end
  end

  describe "disconnect/2" do
    test "CA4: closing the last connection makes the user offline" do
      stub_audience()
      capture_publishes()
      expect_change({:disconnect, "c1"}, {:ok, {:changed, doc("online", [conn("c1")])}})

      assert :ok = Presence.disconnect(@ana, "c1")

      assert_received {:published, "presence:srv-1", "presence_updated",
                       %{"status" => "offline", "version" => 5}}
    end

    test "closing one tab out of two changes nothing for the others" do
      expect_change(
        {:disconnect, "c1"},
        {:ok, {:changed, doc("online", [conn("c1"), conn("c2")])}}
      )

      assert :ok = Presence.disconnect(@ana, "c1")
      refute_received {:published, _, _, _}
    end

    test "a connection that was already gone is fine" do
      expect_change({:disconnect, "c1"}, {:ok, :unchanged})

      assert :ok = Presence.disconnect(@ana, "c1")
    end
  end

  describe "set_activity/3" do
    test "CA2: the only connection going idle makes the user idle" do
      stub_audience()
      capture_publishes()
      expect_change({:activity, "c1", true}, {:ok, {:changed, doc("online", [conn("c1")])}})

      assert :ok = Presence.set_activity(@ana, "c1", true)
      assert_received {:published, "presence:srv-1", "presence_updated", %{"status" => "idle"}}
    end

    test "CA2: one tab idle while the phone is active keeps the user online" do
      expect_change(
        {:activity, "c1", true},
        {:ok, {:changed, doc("online", [conn("c1"), conn("phone")])}}
      )

      assert :ok = Presence.set_activity(@ana, "c1", true)
      refute_received {:published, _, _, _}
    end

    test "CA3: inactivity does not override do not disturb" do
      expect_change({:activity, "c1", true}, {:ok, {:changed, doc("dnd", [conn("c1")])}})

      assert :ok = Presence.set_activity(@ana, "c1", true)
      refute_received {:published, _, _, _}
    end

    test "coming back from idle makes the user online again" do
      stub_audience()
      capture_publishes()

      expect_change(
        {:activity, "c1", false},
        {:ok, {:changed, doc("online", [conn("c1", true)])}}
      )

      assert :ok = Presence.set_activity(@ana, "c1", false)
      assert_received {:published, "presence:srv-1", "presence_updated", %{"status" => "online"}}
    end
  end

  describe "set_manual/2" do
    test "CA3: invisible looks offline to the others and reaches every own session" do
      stub_audience()
      capture_publishes()
      expect_change({:set_manual, "invisible"}, {:ok, {:changed, doc("online", [conn("c1")])}})

      assert :ok = Presence.set_manual(@ana, "invisible")

      assert_received {:published, "presence:srv-1", "presence_updated",
                       %{"status" => "offline", "version" => 5}}

      assert_received {:published, "user:" <> @ana, "own_status_updated",
                       %{"status" => "invisible", "version" => 5}}
    end

    test "CA3: do not disturb is shown as such" do
      stub_audience()
      capture_publishes()
      expect_change({:set_manual, "dnd"}, {:ok, {:changed, doc("online", [conn("c1", true)])}})

      assert :ok = Presence.set_manual(@ana, "dnd")
      assert_received {:published, "presence:srv-1", "presence_updated", %{"status" => "dnd"}}
    end

    test "while offline the choice is kept and only the own sessions hear of it" do
      capture_publishes()
      expect_change({:set_manual, "dnd"}, {:ok, {:changed, doc("online", [])}})

      assert :ok = Presence.set_manual(@ana, "dnd")
      assert_received {:published, "user:" <> @ana, "own_status_updated", %{"status" => "dnd"}}
      refute_received {:published, _, "presence_updated", _}
    end

    test "picking the same status again does nothing" do
      expect_change({:set_manual, "dnd"}, {:ok, :unchanged})

      assert :ok = Presence.set_manual(@ana, "dnd")
      refute_received {:published, _, _, _}
    end

    test "offline is not something you can pick" do
      for bad <- ["offline", "away", nil, 1, %{}] do
        assert {:error, :invalid_status} = Presence.set_manual(@ana, bad)
      end
    end
  end

  test "drop_instance/2: CA4 also when the instance holding the socket died" do
    stub_audience()
    capture_publishes()
    on_dead_instance = Map.put(conn("c1"), "instance", "dead")
    expect_change({:drop_instance, "dead"}, {:ok, {:changed, doc("online", [on_dead_instance])}})

    assert :ok = Presence.drop_instance(@ana, "dead")
    assert_received {:published, "presence:srv-1", "presence_updated", %{"status" => "offline"}}
  end

  describe "audience" do
    test "a DM partner with a block in either direction does not hear about it" do
      stub_audience([@beto, @cami])
      capture_publishes()

      stub(Messaging.Chat.RepoMock, :get_blocks, fn _ids ->
        {:ok, [%{"_id" => @cami <> ":" <> @ana, "blocker_id" => @cami, "blocked_id" => @ana}]}
      end)

      expect_change({:connect, "c1", "i-1"}, {:ok, {:changed, nil}})
      {:ok, _} = Presence.connect(@ana, "c1", "i-1")

      assert_received {:published, "user:" <> @beto, "presence_updated", _}
      refute_received {:published, "user:" <> @cami, _, _}
    end

    test "if the audience cannot be read the change still counts, and it is logged" do
      stub(Messaging.Presence.StoreMock, :member_server_ids, fn _ -> {:error, :timeout} end)
      expect_change({:connect, "c1", "i-1"}, {:ok, {:changed, nil}})

      log = capture_log(fn -> assert {:ok, "online"} = Presence.connect(@ana, "c1", "i-1") end)
      assert log =~ "presence_audience_failed"
    end

    test "a failed publish is logged and the rest still go out" do
      stub_audience()
      test_pid = self()

      stub(Messaging.EventPublisherMock, :publish_event, fn
        _id, "presence:srv-1", _event, _payload ->
          {:error, :not_connected}

        _id, topic, _event, _payload ->
          send(test_pid, {:published, topic})
          :ok
      end)

      expect_change({:connect, "c1", "i-1"}, {:ok, {:changed, nil}})

      log = capture_log(fn -> {:ok, _} = Presence.connect(@ana, "c1", "i-1") end)
      assert log =~ "presence_publish_failed"
      assert_received {:published, "user:" <> @beto}
    end
  end

  describe "snapshot/2" do
    test "keeps the order asked for, with offline and version 0 for users never seen" do
      expect(Messaging.Presence.StoreMock, :get_many, fn [@beto, @cami] ->
        {:ok,
         [%{"_id" => @beto, "manual" => "dnd", "connections" => [conn("x")], "version" => 7}]}
      end)

      stub(Messaging.Chat.RepoMock, :get_blocks, fn _ids -> {:ok, []} end)

      assert {:ok,
              [
                %{"user_id" => @beto, "status" => "dnd", "version" => 7},
                %{"user_id" => @cami, "status" => "offline", "version" => 0}
              ]} = Presence.snapshot(@ana, [@beto, @cami])
    end

    test "someone with a block with the viewer shows offline" do
      expect(Messaging.Presence.StoreMock, :get_many, fn _ids ->
        {:ok, [%{"_id" => @beto, "connections" => [conn("x")], "version" => 2}]}
      end)

      expect(Messaging.Chat.RepoMock, :get_blocks, fn ids ->
        assert Enum.sort(ids) == Enum.sort([@ana <> ":" <> @beto, @beto <> ":" <> @ana])
        {:ok, [%{"_id" => @ana <> ":" <> @beto, "blocker_id" => @ana, "blocked_id" => @beto}]}
      end)

      assert {:ok, [%{"user_id" => @beto, "status" => "offline", "version" => 2}]} =
               Presence.snapshot(@ana, [@beto])
    end

    test "blocks are only checked for who is not offline anyway" do
      expect(Messaging.Presence.StoreMock, :get_many, fn _ids -> {:ok, []} end)

      assert {:ok, [%{"status" => "offline"}]} = Presence.snapshot(@ana, [@beto])
    end

    test "nothing asked, nothing read" do
      assert {:ok, []} = Presence.snapshot(@ana, [])
    end
  end

  describe "server_snapshot/2" do
    test "returns only the members that are not offline" do
      expect(Messaging.Chat.RepoMock, :get_member, fn "srv-1", @ana -> %{"user_id" => @ana} end)

      expect(Messaging.Chat.RepoMock, :list_members, fn "srv-1" ->
        {:ok, [%{"user_id" => @ana}, %{"user_id" => @beto}, %{"user_id" => @cami}]}
      end)

      expect(Messaging.Presence.StoreMock, :get_many, fn [@ana, @beto, @cami] ->
        {:ok,
         [
           %{"_id" => @ana, "connections" => [conn("a")], "version" => 1},
           %{
             "_id" => @beto,
             "manual" => "invisible",
             "connections" => [conn("b")],
             "version" => 3
           }
         ]}
      end)

      stub(Messaging.Chat.RepoMock, :get_blocks, fn _ids -> {:ok, []} end)

      assert {:ok, [%{"user_id" => @ana, "status" => "online", "version" => 1}]} =
               Presence.server_snapshot(@ana, "srv-1")
    end

    test "only members can see the presence of a server" do
      expect(Messaging.Chat.RepoMock, :get_member, fn "srv-1", @ana -> nil end)

      assert {:error, :forbidden} = Presence.server_snapshot(@ana, "srv-1")
    end
  end

  test "idle_after_ms/0 has a default of five minutes" do
    assert Presence.idle_after_ms() == 300_000
  end

  describe "push state events" do
    defp push_event do
      assert_received {:outbox, [event]}
      event
    end

    test "the first connection tells the other services the user is active" do
      stub_audience()
      capture_publishes()
      expect_change({:connect, "c1", "i-1"}, {:ok, {:changed, doc("online", [], 4)}})

      assert {:ok, "online"} = Presence.connect(@ana, "c1", "i-1")

      event = push_event()
      assert event.event == "messaging.user_presence_changed"
      assert event.topic == "domain"
      refute Map.has_key?(event, :message_id)

      assert %{
               "user_id" => @ana,
               "connections" => "active",
               "do_not_disturb" => false,
               "version" => 5,
               "occurred_at" => occurred_at
             } = event.payload

      assert {:ok, _at, _offset} = DateTime.from_iso8601(occurred_at)
    end

    test "a second tab does not repeat what the others already know" do
      expect_change({:connect, "c2", "i-1"}, {:ok, {:changed, doc("online", [conn("c1")])}})

      assert {:ok, "online"} = Presence.connect(@ana, "c2", "i-1")
      refute_received {:outbox, _}
    end

    test "the only connection going idle is reported as idle" do
      stub_audience()
      capture_publishes()
      expect_change({:activity, "c1", true}, {:ok, {:changed, doc("online", [conn("c1")])}})

      assert :ok = Presence.set_activity(@ana, "c1", true)
      assert push_event().payload["connections"] == "idle"
    end

    test "coming back from idle is reported as active again" do
      stub_audience()
      capture_publishes()

      expect_change(
        {:activity, "c1", false},
        {:ok, {:changed, doc("online", [conn("c1", true)])}}
      )

      assert :ok = Presence.set_activity(@ana, "c1", false)
      assert push_event().payload["connections"] == "active"
    end

    test "one idle tab while another stays active changes nothing" do
      expect_change(
        {:activity, "c1", true},
        {:ok, {:changed, doc("online", [conn("c1"), conn("phone")])}}
      )

      assert :ok = Presence.set_activity(@ana, "c1", true)
      refute_received {:outbox, _}
    end

    test "choosing do not disturb is reported, keeping the connections as they are" do
      stub_audience()
      capture_publishes()
      expect_change({:set_manual, "dnd"}, {:ok, {:changed, doc("online", [conn("c1")])}})

      assert :ok = Presence.set_manual(@ana, "dnd")

      assert %{"connections" => "active", "do_not_disturb" => true} = push_event().payload
    end

    test "leaving do not disturb is reported" do
      stub_audience()
      capture_publishes()
      expect_change({:set_manual, "online"}, {:ok, {:changed, doc("dnd", [conn("c1")])}})

      assert :ok = Presence.set_manual(@ana, "online")

      assert %{"do_not_disturb" => false} = push_event().payload
    end

    test "being invisible or idle by choice does not change who gets a push" do
      for choice <- ["invisible", "idle"] do
        stub_audience()
        capture_publishes()
        expect_change({:set_manual, choice}, {:ok, {:changed, doc("online", [conn("c1")])}})

        assert :ok = Presence.set_manual(@ana, choice)
        refute_received {:outbox, _}
      end
    end

    test "an invisible user with the app open still counts as active" do
      stub_audience()
      capture_publishes()
      expect_change({:connect, "c2", "i-1"}, {:ok, {:changed, doc("invisible", [])}})

      assert {:ok, "invisible"} = Presence.connect(@ana, "c2", "i-1")
      assert push_event().payload["connections"] == "active"
    end

    test "closing the last connection is reported as none" do
      stub_audience()
      capture_publishes()
      expect_change({:disconnect, "c1"}, {:ok, {:changed, doc("online", [conn("c1")])}})

      assert :ok = Presence.disconnect(@ana, "c1")
      assert push_event().payload["connections"] == "none"
    end

    test "closing one tab out of two reports nothing" do
      expect_change(
        {:disconnect, "c1"},
        {:ok, {:changed, doc("online", [conn("c1"), conn("c2")])}}
      )

      assert :ok = Presence.disconnect(@ana, "c1")
      refute_received {:outbox, _}
    end

    test "an instance that died takes its connections with it, and that is reported" do
      stub_audience()
      capture_publishes()
      on_dead_instance = Map.put(conn("c1"), "instance", "dead")

      expect_change(
        {:drop_instance, "dead"},
        {:ok, {:changed, doc("online", [on_dead_instance])}}
      )

      assert :ok = Presence.drop_instance(@ana, "dead")
      assert push_event().payload["connections"] == "none"
    end

    test "a change that did not happen reports nothing" do
      expect_change({:disconnect, "c1"}, {:ok, :unchanged})

      assert :ok = Presence.disconnect(@ana, "c1")
      refute_received {:outbox, _}
    end

    test "the version travels with the event, growing with each change" do
      stub_audience()
      capture_publishes()
      expect_change({:disconnect, "c1"}, {:ok, {:changed, doc("online", [conn("c1")], 41)}})

      assert :ok = Presence.disconnect(@ana, "c1")
      assert push_event().payload["version"] == 42
    end

    test "if the event cannot be queued the presence change still counts, and it is logged" do
      stub_audience()
      capture_publishes()
      stub(Messaging.Outbox.StoreMock, :insert, fn _rows -> {:error, :timeout} end)
      expect_change({:disconnect, "c1"}, {:ok, {:changed, doc("online", [conn("c1")])}})

      log =
        capture_log(fn ->
          assert :ok = Presence.disconnect(@ana, "c1")
        end)

      assert log =~ "presence_event_enqueue_failed"
      assert_received {:published, "presence:srv-1", "presence_updated", %{"status" => "offline"}}
    end
  end
end
