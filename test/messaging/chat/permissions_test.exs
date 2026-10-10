defmodule Messaging.Chat.PermissionsTest do
  use ExUnit.Case, async: true

  alias Messaging.Chat.Permissions

  @everyone "everyone"
  @mod "mod"
  @vip "vip"

  defp roles do
    %{
      @everyone => %{permissions: ["VIEW_CHANNELS", "SEND_MESSAGES"], is_everyone: true},
      @mod => %{permissions: ["MANAGE_MESSAGES"], is_everyone: false},
      @vip => %{permissions: ["MENTION_EVERYONE"], is_everyone: false},
      "admin" => %{permissions: ["ADMINISTRATOR"], is_everyone: false}
    }
  end

  defp effective(role_ids, overrides \\ %{}, owner? \\ false),
    do: Permissions.effective(owner?, role_ids, roles(), overrides)

  defp override(allow, deny), do: %{allow: allow, deny: deny}

  describe "effective/4 without overrides" do
    test "is the union of the permissions of the member's roles" do
      assert effective([@everyone, @mod]) ==
               MapSet.new(["VIEW_CHANNELS", "SEND_MESSAGES", "MANAGE_MESSAGES"])
    end

    test "a member without roles can do nothing" do
      assert effective([]) == MapSet.new()
    end

    test "unknown roles grant nothing" do
      assert effective([@everyone, "deleted-role"]) ==
               MapSet.new(["VIEW_CHANNELS", "SEND_MESSAGES"])
    end

    test "the owner can do everything" do
      assert effective([], %{}, true) == Permissions.all()
    end

    test "a role with ADMINISTRATOR can do everything" do
      assert effective([@everyone, "admin"]) == Permissions.all()
    end
  end

  describe "effective/4 with overrides" do
    test "the @everyone override applies to everybody" do
      overrides = %{@everyone => override([], ["SEND_MESSAGES"])}

      assert effective([@everyone], overrides) == MapSet.new(["VIEW_CHANNELS"])
    end

    test "a role override can give back what @everyone's took away" do
      overrides = %{
        @everyone => override([], ["SEND_MESSAGES"]),
        @vip => override(["SEND_MESSAGES"], [])
      }

      assert effective([@everyone, @vip], overrides) ==
               MapSet.new(["VIEW_CHANNELS", "SEND_MESSAGES", "MENTION_EVERYONE"])
    end

    test "within the role layer allow wins over deny" do
      overrides = %{
        @mod => override([], ["VIEW_CHANNELS"]),
        @vip => override(["VIEW_CHANNELS"], [])
      }

      assert Permissions.can?(effective([@everyone, @mod, @vip], overrides), "VIEW_CHANNELS")
    end

    test "a role override can allow what the server-wide permissions do not" do
      overrides = %{@mod => override(["VIEW_CHANNELS"], [])}

      assert Permissions.can?(effective([@mod], overrides), "VIEW_CHANNELS")
    end

    test "overrides of roles the member does not hold are ignored" do
      overrides = %{@vip => override([], ["VIEW_CHANNELS"])}

      assert Permissions.can?(effective([@everyone], overrides), "VIEW_CHANNELS")
    end

    test "overrides never apply to the owner or to administrators" do
      overrides = %{@everyone => override([], ["VIEW_CHANNELS", "SEND_MESSAGES"])}

      assert effective([@everyone], overrides, true) == Permissions.all()
      assert effective([@everyone, "admin"], overrides) == Permissions.all()
    end

    test "an override on a deleted role is ignored" do
      overrides = %{"deleted-role" => override([], ["VIEW_CHANNELS"])}

      assert Permissions.can?(effective([@everyone, "deleted-role"], overrides), "VIEW_CHANNELS")
    end
  end

  describe "server_wide/3" do
    test "ignores channel overrides and keeps owner and administrator implicit" do
      assert Permissions.server_wide(false, [@everyone], roles()) ==
               MapSet.new(["VIEW_CHANNELS", "SEND_MESSAGES"])

      assert Permissions.server_wide(true, [], roles()) == Permissions.all()
      assert Permissions.server_wide(false, ["admin"], roles()) == Permissions.all()
    end
  end
end
