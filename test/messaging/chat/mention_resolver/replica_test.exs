defmodule Messaging.Chat.MentionResolver.ReplicaTest do
  use ExUnit.Case, async: true
  import Mox

  alias Messaging.Chat.MentionResolver.Replica
  alias Messaging.Chat.Mentions
  alias Messaging.ReplicaFixtures, as: Fixtures

  setup :verify_on_exit!

  defp members do
    [
      Fixtures.member("actor", ["everyone"]),
      Fixtures.member("ana", ["everyone"]),
      Fixtures.member("beto", ["everyone", "mod"]),
      Fixtures.member("caro", ["everyone", "mod"]),
      Fixtures.member("dani", ["everyone"])
    ]
  end

  defp setup_server(opts \\ []) do
    Fixtures.stub_server(Keyword.get(opts, :owner, "owner-1"), Keyword.get(opts, :overrides, []))
    all = Keyword.get(opts, :members, members())

    stub(Messaging.Chat.RepoMock, :get_member, fn "srv-1", user_id ->
      Enum.find(all, &(&1["user_id"] == user_id))
    end)

    stub(Messaging.Chat.RepoMock, :get_members, fn "srv-1", user_ids ->
      {:ok, Enum.filter(all, &(&1["user_id"] in user_ids))}
    end)

    stub(Messaging.Chat.RepoMock, :list_members, fn "srv-1" -> {:ok, all} end)
  end

  defp resolve(query, actor \\ "actor") do
    Replica.resolve(
      Fixtures.channel(),
      Map.merge(%{user_ids: [], role_ids: [], everyone: false}, query),
      actor
    )
  end

  test "a mentioned member is a recipient" do
    setup_server()

    assert {:ok,
            %Mentions{user_ids: ["ana"], role_ids: [], everyone: false, recipient_ids: ["ana"]}} =
             resolve(%{user_ids: ["ana"]})
  end

  test "someone who is not a member of the server is dropped" do
    setup_server()

    assert {:ok, %Mentions{user_ids: ["ana"], recipient_ids: ["ana"]}} =
             resolve(%{user_ids: ["ana", "ghost"]})
  end

  test "the actor is never their own recipient" do
    setup_server()

    assert {:ok, %Mentions{user_ids: ["actor"], recipient_ids: []}} =
             resolve(%{user_ids: ["actor"]})
  end

  test "a member who cannot see the channel is mentioned but not notified" do
    setup_server(overrides: [Fixtures.override("everyone", [], ["VIEW_CHANNELS"])])

    assert {:ok, %Mentions{user_ids: ["ana"], recipient_ids: []}} = resolve(%{user_ids: ["ana"]})
  end

  test "without MENTION_EVERYONE, roles and @everyone are dropped and the text stays plain" do
    setup_server()

    assert {:ok, %Mentions{role_ids: [], everyone: false, recipient_ids: []}} =
             resolve(%{role_ids: ["mod"], everyone: true})
  end

  test "with MENTION_EVERYONE a role reaches everyone who holds it" do
    setup_server(members: [Fixtures.member("actor", ["everyone", "vip"]) | tl(members())])

    assert {:ok, %Mentions{role_ids: ["mod"], everyone: false, recipient_ids: ["beto", "caro"]}} =
             resolve(%{role_ids: ["mod"]})
  end

  test "a role that does not exist, or @everyone as a role id, is dropped" do
    setup_server(owner: "actor")

    assert {:ok, %Mentions{role_ids: ["mod"]}} =
             resolve(%{role_ids: ["mod", "deleted-role", "everyone"]})
  end

  test "the owner can mention everybody, and @everyone reaches every member who sees the channel" do
    setup_server(
      owner: "actor",
      overrides: [
        Fixtures.override("everyone", [], ["VIEW_CHANNELS"]),
        Fixtures.override("mod", ["VIEW_CHANNELS"], [])
      ]
    )

    assert {:ok, %Mentions{everyone: true, recipient_ids: ["beto", "caro"]}} =
             resolve(%{everyone: true})
  end

  test "@everyone reaches all the members when the channel is public" do
    setup_server(owner: "actor")

    assert {:ok, %Mentions{everyone: true, recipient_ids: ["ana", "beto", "caro", "dani"]}} =
             resolve(%{everyone: true})
  end

  test "an administrator can mention everybody" do
    setup_server(members: [Fixtures.member("actor", ["everyone", "admin"]) | tl(members())])

    assert {:ok, %Mentions{everyone: true}} = resolve(%{everyone: true})
  end

  test "a user, a role and a repeated person are told once" do
    setup_server(owner: "actor")

    assert {:ok,
            %Mentions{user_ids: ["beto"], role_ids: ["mod"], recipient_ids: ["beto", "caro"]}} =
             resolve(%{user_ids: ["beto"], role_ids: ["mod"]})
  end

  test "an actor who is not a member cannot resolve anything" do
    setup_server(members: tl(members()))

    assert {:error, :not_a_member} = resolve(%{user_ids: ["ana"]})
  end

  test "a failing read is returned" do
    Fixtures.stub_server("owner-1")
    stub(Messaging.Chat.RepoMock, :get_member, fn _server, _user -> {:error, :timeout} end)

    assert {:error, :timeout} = resolve(%{user_ids: ["ana"]})
  end
end
