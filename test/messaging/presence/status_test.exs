defmodule Messaging.Presence.StatusTest do
  use ExUnit.Case, async: true

  alias Messaging.Presence.Status

  defp doc(manual, connections),
    do: %{"manual" => manual, "connections" => connections, "version" => 3}

  defp conn(id, idle, instance \\ "i-1"),
    do: %{"id" => id, "instance" => instance, "idle" => idle}

  describe "effective/1" do
    test "CA4: without connections the user is offline, whatever they picked" do
      for manual <- Status.choices() do
        assert Status.effective(doc(manual, [])) == "offline"
      end

      assert Status.effective(nil) == "offline"
    end

    test "CA1: connected and active is online" do
      assert Status.effective(doc("online", [conn("a", false)])) == "online"
    end

    test "CA2: idle only when every connection is idle" do
      assert Status.effective(doc("online", [conn("a", true)])) == "idle"
      assert Status.effective(doc("online", [conn("a", true), conn("b", true)])) == "idle"
      assert Status.effective(doc("online", [conn("a", true), conn("b", false)])) == "online"
    end

    test "CA3: do not disturb is kept even while inactive" do
      assert Status.effective(doc("dnd", [conn("a", false)])) == "dnd"
      assert Status.effective(doc("dnd", [conn("a", true)])) == "dnd"
    end

    test "CA3: invisible looks offline to the others" do
      assert Status.effective(doc("invisible", [conn("a", false)])) == "offline"
      assert Status.effective(doc("invisible", [conn("a", true)])) == "offline"
    end

    test "idle picked by hand stays idle while active" do
      assert Status.effective(doc("idle", [conn("a", false)])) == "idle"
    end

    test "a document without manual counts as online" do
      assert Status.effective(%{"connections" => [conn("a", false)]}) == "online"
    end
  end

  describe "apply_change/2" do
    test "connect adds an active connection and bumps the version" do
      after_doc = Status.apply_change(doc("dnd", []), {:connect, "a", "i-1"})

      assert after_doc["connections"] == [conn("a", false)]
      assert after_doc["manual"] == "dnd"
      assert after_doc["version"] == 4
    end

    test "connect on a user never seen starts online at version 1" do
      after_doc = Status.apply_change(nil, {:connect, "a", "i-1"})

      assert after_doc["manual"] == "online"
      assert after_doc["version"] == 1
      assert Status.effective(after_doc) == "online"
    end

    test "disconnect removes only that connection" do
      after_doc =
        Status.apply_change(
          doc("online", [conn("a", false), conn("b", true)]),
          {:disconnect, "a"}
        )

      assert after_doc["connections"] == [conn("b", true)]
    end

    test "activity flips the flag of one connection" do
      after_doc =
        Status.apply_change(
          doc("online", [conn("a", false), conn("b", false)]),
          {:activity, "b", true}
        )

      assert after_doc["connections"] == [conn("a", false), conn("b", true)]
    end

    test "set_manual keeps the connections" do
      after_doc =
        Status.apply_change(doc("online", [conn("a", false)]), {:set_manual, "invisible"})

      assert after_doc["manual"] == "invisible"
      assert after_doc["connections"] == [conn("a", false)]
    end

    test "drop_instance removes every connection of that instance" do
      before =
        doc("online", [
          conn("a", false, "dead"),
          conn("b", false, "alive"),
          conn("c", true, "dead")
        ])

      after_doc = Status.apply_change(before, {:drop_instance, "dead"})

      assert after_doc["connections"] == [conn("b", false, "alive")]
    end
  end

  test "only the four choices can be picked" do
    assert Status.valid_choice?("dnd")
    assert Status.valid_choice?("invisible")
    refute Status.valid_choice?("offline")
    refute Status.valid_choice?(nil)
  end

  test "manual/1 and version/1 have defaults for a user never seen" do
    assert Status.manual(nil) == "online"
    assert Status.version(nil) == 0
  end
end
