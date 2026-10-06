defmodule Messaging.Chat.MentionsTest do
  use ExUnit.Case, async: true

  alias Messaging.Chat.Mentions

  @role "9b1e2c3d-4e5f-4a6b-8c7d-0e1f2a3b4c5d"

  describe "parse/1" do
    test "finds users, roles and @everyone" do
      assert %{user_ids: ["ana"], role_ids: [@role], everyone: true} =
               Mentions.parse("hola <@ana>, <@&#{@role}> y @everyone")
    end

    test "plain text has no mentions" do
      query = Mentions.parse("hola a todos, nos vemos a las 5")
      assert query == %{user_ids: [], role_ids: [], everyone: false}
      refute Mentions.any?(query)
    end

    test "a plain @name is just text: only tokens with an id mention someone" do
      assert %{user_ids: []} = Mentions.parse("gracias @ana")
    end

    test "repeated mentions count once, keeping the first-seen order" do
      assert %{user_ids: ["bob", "ana"], role_ids: [@role]} =
               Mentions.parse("<@bob> <@ana> <@bob> <@&#{@role}> <@&#{String.upcase(@role)}>")
    end

    test "role ids are normalized to lowercase, like servers returns them" do
      assert %{role_ids: [@role]} = Mentions.parse("<@&#{String.upcase(@role)}>")
    end

    test "a role token is never mistaken for a user token" do
      assert %{user_ids: [], role_ids: [@role]} = Mentions.parse("<@&#{@role}>")
    end

    test "role tokens need a real UUID" do
      assert %{role_ids: [], user_ids: []} = Mentions.parse("<@&no-es-un-uuid>")
    end

    test "user tokens follow the user id format (no spaces, max 64 chars)" do
      too_long = String.duplicate("a", 65)

      assert %{user_ids: ["ok_id-1"]} =
               Mentions.parse("<@ok_id-1> <@con espacio> <@#{too_long}> <@>")
    end

    test "@everyone only counts as a word of its own" do
      for text <- ["@everyone", "hola @everyone!", "(@everyone)", "@everyone, mañana"] do
        assert Mentions.parse(text).everyone, "expected #{inspect(text)} to mention everyone"
      end

      for text <- ["mail@everyone.com", "@everyoneee", "@@everyone", "<@everyone>", "@here"] do
        refute Mentions.parse(text).everyone, "expected #{inspect(text)} to be plain text"
      end
    end

    test "caps how many users and roles one message can mention" do
      users = Enum.map_join(1..60, " ", &"<@u#{&1}>")

      roles =
        Enum.map_join(1..25, " ", fn i ->
          "<@&00000000-0000-4000-8000-#{String.pad_leading(Integer.to_string(i), 12, "0")}>"
        end)

      query = Mentions.parse(users <> " " <> roles)

      assert length(query.user_ids) == 50
      assert length(query.role_ids) == 20
    end
  end

  test "message_fields/1 is what a message stores" do
    resolution = %Mentions{
      user_ids: ["ana"],
      role_ids: [@role],
      everyone: true,
      recipient_ids: ["ana", "bob"]
    }

    assert Mentions.message_fields(resolution) == %{
             "mentions" => ["ana"],
             "mention_roles" => [@role],
             "mention_everyone" => true
           }
  end

  test "none/0 reaches nobody" do
    assert %Mentions{user_ids: [], role_ids: [], everyone: false, recipient_ids: []} =
             Mentions.none()
  end
end
