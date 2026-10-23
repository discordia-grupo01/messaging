mongo_url = System.get_env("MONGO_URL")

if mongo_url do
  defmodule Messaging.Presence.Store.MongoTest do
    use ExUnit.Case, async: false

    alias Messaging.Presence.Status
    alias Messaging.Presence.Store.Mongo, as: Store

    setup do
      {:ok, user: Messaging.UUID.generate()}
    end

    defp stored(user) do
      {:ok, [doc]} = Store.get_many([user])
      doc
    end

    defp connections(doc),
      do: Enum.map(doc["connections"], &Map.take(&1, ["id", "instance", "idle"]))

    describe "change/2" do
      test "the first connection creates the document online, at version 1", %{user: user} do
        assert {:ok, {:changed, nil}} = Store.change(user, {:connect, "c1", "i-1"})

        doc = stored(user)
        assert doc["manual"] == "online"
        assert doc["version"] == 1
        assert [%{"id" => "c1", "instance" => "i-1", "idle" => false}] = doc["connections"]
        assert Status.effective(doc) == "online"
      end

      test "many first connections at once keep every connection", %{user: user} do
        1..10
        |> Enum.map(fn n -> Task.async(fn -> Store.change(user, {:connect, "c#{n}", "i"}) end) end)
        |> Enum.each(&({:ok, {:changed, _before}} = Task.await(&1)))

        doc = stored(user)
        assert length(doc["connections"]) == 10
        assert doc["version"] == 10
      end

      test "each change returns the document as it was before", %{user: user} do
        {:ok, {:changed, nil}} = Store.change(user, {:connect, "c1", "i-1"})

        assert {:ok, {:changed, before}} = Store.change(user, {:connect, "c2", "i-1"})
        assert before["version"] == 1
        assert length(before["connections"]) == 1
        assert stored(user)["version"] == 2
      end

      test "disconnect removes only that connection", %{user: user} do
        {:ok, _} = Store.change(user, {:connect, "c1", "i-1"})
        {:ok, _} = Store.change(user, {:connect, "c2", "i-1"})

        assert {:ok, {:changed, _before}} = Store.change(user, {:disconnect, "c1"})
        assert [%{"id" => "c2"}] = stored(user)["connections"]
      end

      test "disconnecting a connection that is gone changes nothing", %{user: user} do
        {:ok, _} = Store.change(user, {:connect, "c1", "i-1"})

        assert {:ok, :unchanged} = Store.change(user, {:disconnect, "nope"})
        assert {:ok, :unchanged} = Store.change(Messaging.UUID.generate(), {:disconnect, "c1"})
        assert stored(user)["version"] == 1
      end

      test "activity flips the flag only when it changes", %{user: user} do
        {:ok, _} = Store.change(user, {:connect, "c1", "i-1"})

        assert {:ok, {:changed, _}} = Store.change(user, {:activity, "c1", true})
        assert {:ok, :unchanged} = Store.change(user, {:activity, "c1", true})
        assert [%{"idle" => true}] = stored(user)["connections"]
        assert stored(user)["version"] == 2
      end

      test "set_manual keeps the connections and is a no-op when repeated", %{user: user} do
        {:ok, _} = Store.change(user, {:connect, "c1", "i-1"})

        assert {:ok, {:changed, _}} = Store.change(user, {:set_manual, "dnd"})
        assert {:ok, :unchanged} = Store.change(user, {:set_manual, "dnd"})

        doc = stored(user)
        assert doc["manual"] == "dnd"
        assert length(doc["connections"]) == 1
        assert doc["version"] == 2
      end

      test "set_manual without connections keeps the choice for the next session", %{user: user} do
        assert {:ok, {:changed, nil}} = Store.change(user, {:set_manual, "invisible"})
        {:ok, _} = Store.change(user, {:connect, "c1", "i-1"})

        assert stored(user)["manual"] == "invisible"
        assert Status.effective(stored(user)) == "offline"
      end

      test "drop_instance removes the connections of that instance only", %{user: user} do
        {:ok, _} = Store.change(user, {:connect, "c1", "dead"})
        {:ok, _} = Store.change(user, {:connect, "c2", "alive"})

        assert {:ok, {:changed, _}} = Store.change(user, {:drop_instance, "dead"})
        assert [%{"id" => "c2"}] = stored(user)["connections"]
      end

      test "the stored document always matches Status.apply_change/2", %{user: user} do
        changes = [
          {:connect, "c1", "i-1"},
          {:connect, "c2", "i-2"},
          {:activity, "c1", true},
          {:set_manual, "dnd"},
          {:disconnect, "c2"},
          {:drop_instance, "i-1"}
        ]

        for change <- changes do
          {:ok, {:changed, before}} = Store.change(user, change)
          expected = Status.apply_change(before, change)
          doc = stored(user)

          assert doc["version"] == expected["version"]
          assert doc["manual"] == expected["manual"]
          assert connections(doc) == connections(expected)
        end
      end
    end

    test "user_ids_on_instance/1 finds who has a connection there", %{user: user} do
      instance = Messaging.UUID.generate()
      other = Messaging.UUID.generate()
      {:ok, _} = Store.change(user, {:connect, "c1", instance})
      {:ok, _} = Store.change(other, {:connect, "c1", "elsewhere"})

      assert {:ok, [^user]} = Store.user_ids_on_instance(instance)
    end

    test "instances older than the cutoff are stale" do
      fresh = Messaging.UUID.generate()
      old = Messaging.UUID.generate()
      now = DateTime.utc_now()

      :ok = Store.heartbeat(fresh, now)
      :ok = Store.heartbeat(old, DateTime.add(now, -120, :second))

      {:ok, stale} = Store.stale_instances(DateTime.add(now, -60, :second))
      assert old in stale
      refute fresh in stale

      :ok = Store.delete_instance(old)
      {:ok, stale} = Store.stale_instances(DateTime.add(now, -60, :second))
      refute old in stale
    end

    test "member_server_ids/1 reads the replica and skips servers the user left", %{user: user} do
      Mongo.insert_many(Messaging.Mongo, "replica_members", [
        %{"_id" => "srv-a:" <> user, "server_id" => "srv-a", "user_id" => user},
        %{"_id" => "srv-b:" <> user, "server_id" => "srv-b", "user_id" => user, "deleted" => true}
      ])

      assert {:ok, ["srv-a"]} = Store.member_server_ids(user)
    end

    test "dm_partner_ids/2 lists the other side of each conversation", %{user: user} do
      partner = Messaging.UUID.generate()

      Mongo.insert_one(Messaging.Mongo, "channels", %{
        "_id" => Messaging.UUID.generate(),
        "kind" => "dm",
        "participants" => Enum.sort([user, partner])
      })

      assert {:ok, [^partner]} = Store.dm_partner_ids(user, 10)
    end

    test "ensure_indexes/0 can run more than once" do
      assert :ok = Store.ensure_indexes()
      assert :ok = Store.ensure_indexes()
    end
  end
end
