defmodule Messaging.Chat.SearchTest do
  use ExUnit.Case, async: true
  import Mox

  alias Messaging.Chat
  alias Messaging.ReplicaFixtures, as: Fixtures

  setup :verify_on_exit!

  @at ~U[2026-10-24 12:00:00.000Z]

  setup do
    Messaging.SuspensionHelper.stub_active()

    staff = [
      Fixtures.override("everyone", [], ["VIEW_CHANNELS"]),
      Fixtures.override("mod", ["VIEW_CHANNELS"], [])
    ]

    stub(Messaging.Chat.RepoMock, :get_member, fn "srv-1", user_id ->
      roles = %{"ana" => ["everyone"], "mia" => ["everyone", "mod"]}
      if roles[user_id], do: Fixtures.member(user_id, roles[user_id])
    end)

    stub(Messaging.Chat.RepoMock, :get_server_owner, fn "srv-1" -> "owner-1" end)
    stub(Messaging.Chat.RepoMock, :list_roles, fn "srv-1" -> {:ok, Fixtures.roles()} end)

    stub(Messaging.Chat.RepoMock, :list_text_channel_ids, fn "srv-1" ->
      {:ok, ~w(general staff)}
    end)

    stub(Messaging.Chat.RepoMock, :list_channel_overrides, fn ids ->
      {:ok, Map.take(%{"staff" => staff}, ids)}
    end)

    :ok
  end

  defp search(params),
    do: Chat.search_messages(Map.merge(%{server_id: "srv-1", user_id: "ana"}, params))

  defp doc(id, user_id \\ "ana") do
    %{
      "_id" => id,
      "channel_id" => "general",
      "server_id" => "srv-1",
      "user_id" => user_id,
      "content" => "deploy listo",
      "inserted_at" => @at
    }
  end

  defp count_returns(n) do
    expect(Messaging.Chat.RepoMock, :count_search_matches, fn _ids, _opts, _cap -> {:ok, n} end)
  end

  describe "CA 1: search by text" do
    test "looks only in the text channels the member can view" do
      expect(Messaging.Chat.RepoMock, :search_messages, fn ["general"], opts ->
        assert opts[:text] == "deploy"
        assert opts[:author_id] == nil
        assert opts[:before] == nil
        {:ok, [doc("m2"), doc("m1")]}
      end)

      count_returns(2)

      assert {:ok, page} = search(%{text: "deploy"})
      assert Enum.map(page.messages, & &1.id) == ["m2", "m1"]
      assert page.next_cursor == nil
      assert page.total == %{count: 2, capped: false}
    end

    test "a member whose role shows the hidden channel searches there too" do
      expect(Messaging.Chat.RepoMock, :search_messages, fn ["general", "staff"], _opts ->
        {:ok, []}
      end)

      count_returns(0)

      assert {:ok, _page} = search(%{user_id: "mia", text: "deploy"})
    end

    test "the term is trimmed before searching" do
      expect(Messaging.Chat.RepoMock, :search_messages, fn _ids, opts ->
        assert opts[:text] == "deploy"
        {:ok, []}
      end)

      count_returns(0)

      assert {:ok, _page} = search(%{text: "  deploy  "})
    end
  end

  describe "CA 2: filter by author" do
    test "the author reaches the query, alone or with the text" do
      expect(Messaging.Chat.RepoMock, :search_messages, 2, fn ["general"], opts ->
        assert opts[:author_id] == "beto"
        {:ok, [doc("m1", "beto")]}
      end)

      expect(Messaging.Chat.RepoMock, :count_search_matches, 2, fn _ids, opts, _cap ->
        assert opts[:author_id] == "beto"
        {:ok, 1}
      end)

      assert {:ok, %{messages: [%{user_id: "beto"}]}} = search(%{author_id: "beto"})

      assert {:ok, %{messages: [%{user_id: "beto"}]}} =
               search(%{author_id: "beto", text: "deploy"})
    end
  end

  describe "CA 3: no results" do
    test "an empty page, not an error" do
      expect(Messaging.Chat.RepoMock, :search_messages, fn _ids, _opts -> {:ok, []} end)
      count_returns(0)

      assert {:ok, %{messages: [], next_cursor: nil, total: %{count: 0, capped: false}}} =
               search(%{text: "nada"})
    end

    test "a member who cannot view any channel gets an empty page without searching" do
      stub(Messaging.Chat.RepoMock, :list_text_channel_ids, fn "srv-1" -> {:ok, ["staff"]} end)

      assert {:ok, %{messages: [], next_cursor: nil, total: %{count: 0, capped: false}}} =
               search(%{text: "deploy"})
    end
  end

  describe "validation" do
    test "needs a text or an author" do
      assert {:error, :invalid_search_query} = search(%{})
      assert {:error, :invalid_search_query} = search(%{text: "   ", author_id: ""})
    end

    test "rejects a text longer than the limit" do
      too_long = String.duplicate("a", Chat.Search.max_text_length() + 1)

      assert {:error, :invalid_search_query} = search(%{text: too_long})
    end

    test "rejects a malformed author or a text that is not a string" do
      assert {:error, :invalid_search_query} = search(%{author_id: "not valid!"})
      assert {:error, :invalid_search_query} = search(%{text: ["deploy"]})
    end

    test "a limit out of range falls back to the default page size" do
      expect(Messaging.Chat.RepoMock, :search_messages, fn _ids, opts ->
        assert opts[:limit] == 26
        {:ok, []}
      end)

      count_returns(0)

      assert {:ok, _page} = search(%{text: "deploy", limit: 500})
    end
  end

  describe "access" do
    test "someone who is not a member of the server cannot search it" do
      assert {:error, :not_server_member} = search(%{user_id: "stranger", text: "deploy"})
    end

    test "a channel_id narrows the search to that channel" do
      expect(Messaging.Chat.RepoMock, :search_messages, fn ["staff"], _opts -> {:ok, []} end)
      count_returns(0)

      assert {:ok, _page} = search(%{user_id: "mia", text: "deploy", channel_id: "staff"})
    end

    test "a channel the member cannot view is forbidden" do
      assert {:error, :forbidden} = search(%{text: "deploy", channel_id: "staff"})
    end

    test "a channel that is not a text channel of this server does not exist" do
      assert {:error, :channel_not_found} = search(%{text: "deploy", channel_id: "voice-1"})
    end

    test "a failing read is returned as is" do
      stub(Messaging.Chat.RepoMock, :get_member, fn _server, _user -> {:error, :timeout} end)

      assert {:error, :timeout} = search(%{text: "deploy"})
    end
  end

  describe "pagination and total" do
    test "an extra match means there is a next page, starting after the last one shown" do
      expect(Messaging.Chat.RepoMock, :search_messages, fn _ids, opts ->
        assert opts[:limit] == 3
        {:ok, [doc("m3"), doc("m2"), doc("m1")]}
      end)

      count_returns(3)

      assert {:ok, page} = search(%{text: "deploy", limit: 2})
      assert Enum.map(page.messages, & &1.id) == ["m3", "m2"]
      assert page.next_cursor == "m2"
    end

    test "the next page starts at the cursor and does not count again" do
      stub(Messaging.Chat.RepoMock, :get_message, fn "m2" -> doc("m2") end)

      expect(Messaging.Chat.RepoMock, :search_messages, fn _ids, opts ->
        assert opts[:before] == {@at, "m2"}
        {:ok, [doc("m1")]}
      end)

      assert {:ok, page} = search(%{text: "deploy", before: "m2"})
      assert Enum.map(page.messages, & &1.id) == ["m1"]
      assert page.total == nil
    end

    test "a cursor from another server, or unknown, is rejected" do
      stub(Messaging.Chat.RepoMock, :get_message, fn
        "elsewhere" -> Map.put(doc("elsewhere"), "server_id", "srv-2")
        "missing" -> nil
      end)

      assert {:error, :invalid_cursor} = search(%{text: "deploy", before: "elsewhere"})
      assert {:error, :invalid_cursor} = search(%{text: "deploy", before: "missing"})
    end

    test "the total stops at the cap" do
      cap = Chat.Search.count_cap()
      expect(Messaging.Chat.RepoMock, :search_messages, fn _ids, _opts -> {:ok, []} end)

      expect(Messaging.Chat.RepoMock, :count_search_matches, fn _ids, _opts, limit ->
        assert limit == cap + 1
        {:ok, cap + 1}
      end)

      assert {:ok, %{total: %{count: ^cap, capped: true}}} = search(%{text: "a"})
    end

    test "a failing search is returned as is" do
      expect(Messaging.Chat.RepoMock, :search_messages, fn _ids, _opts -> {:error, :timeout} end)

      assert {:error, :timeout} = search(%{text: "deploy"})
    end
  end
end
