defmodule Messaging.Chat.BlocksTest do
  use ExUnit.Case, async: true
  import Mox

  alias Messaging.Chat.Blocks

  setup :verify_on_exit!

  @me "11111111-1111-4111-8111-111111111111"
  @other "22222222-2222-4222-8222-222222222222"
  @third "33333333-3333-4333-8333-333333333333"

  describe "block/3" do
    test "CA1: stores the block after checking the user exists" do
      expect(Messaging.Chat.UsersClientMock, :user_exists?, fn @other, "jwt" -> {:ok, true} end)

      expect(Messaging.Chat.RepoMock, :put_block, fn doc ->
        assert doc["_id"] == @me <> ":" <> @other
        assert doc["blocker_id"] == @me
        assert doc["blocked_id"] == @other
        assert %DateTime{microsecond: {_micro, 3}} = doc["created_at"]
        :ok
      end)

      assert :ok = Blocks.block(@me, @other, "jwt")
    end

    test "you cannot block yourself and nothing is read or written" do
      assert {:error, :cannot_block_self} = Blocks.block(@me, @me, "jwt")
    end

    test "an id that is not a plain identifier never reaches the services" do
      for bad <- ["", "a.b", "a$b", "../me", "a:b", nil, 5, %{"$ne" => 1}] do
        assert {:error, :user_not_found} = Blocks.block(@me, bad, "jwt")
      end
    end

    test "a user that does not exist cannot be blocked" do
      expect(Messaging.Chat.UsersClientMock, :user_exists?, fn _id, _jwt -> {:ok, false} end)

      assert {:error, :user_not_found} = Blocks.block(@me, @other, "jwt")
    end

    test "if identify-service is unreachable the answer is 'unavailable', never a guess" do
      expect(Messaging.Chat.UsersClientMock, :user_exists?, fn _id, _jwt -> {:error, :timeout} end)

      assert {:error, :users_unavailable} = Blocks.block(@me, @other, "jwt")
    end

    test "a repository failure is propagated" do
      expect(Messaging.Chat.UsersClientMock, :user_exists?, fn _id, _jwt -> {:ok, true} end)
      expect(Messaging.Chat.RepoMock, :put_block, fn _doc -> {:error, :timeout} end)

      assert {:error, :timeout} = Blocks.block(@me, @other, "jwt")
    end
  end

  describe "unblock/2" do
    test "CA3: removes the block" do
      expect(Messaging.Chat.RepoMock, :delete_block, fn id ->
        assert id == @me <> ":" <> @other
        :ok
      end)

      assert :ok = Blocks.unblock(@me, @other)
    end

    test "it does not ask identify-service: a user that disappeared can still be unblocked" do
      expect(Messaging.Chat.RepoMock, :delete_block, fn _id -> :ok end)

      assert :ok = Blocks.unblock(@me, @other)
    end

    test "validates the target like block/3" do
      assert {:error, :cannot_block_self} = Blocks.unblock(@me, @me)
      assert {:error, :user_not_found} = Blocks.unblock(@me, "a.b")
    end

    test "a repository failure is propagated" do
      expect(Messaging.Chat.RepoMock, :delete_block, fn _id -> {:error, :timeout} end)

      assert {:error, :timeout} = Blocks.unblock(@me, @other)
    end
  end

  describe "list/2" do
    test "returns only the id and the date of each block, in the order the repo gives" do
      at = ~U[2026-10-06 12:00:00.000Z]

      expect(Messaging.Chat.RepoMock, :list_blocks, fn @me, 50 ->
        {:ok,
         [
           %{"_id" => "x", "blocker_id" => @me, "blocked_id" => @other, "created_at" => at},
           %{"_id" => "y", "blocker_id" => @me, "blocked_id" => @third, "created_at" => at}
         ]}
      end)

      assert {:ok, [%{user_id: @other, created_at: ^at}, %{user_id: @third}] = blocks} =
               Blocks.list(@me)

      assert Enum.all?(blocks, &(Map.keys(&1) |> Enum.sort() == [:created_at, :user_id]))
    end

    test "the limit is clamped" do
      expect(Messaging.Chat.RepoMock, :list_blocks, fn _id, 100 -> {:ok, []} end)
      assert {:ok, []} = Blocks.list(@me, limit: 100)

      expect(Messaging.Chat.RepoMock, :list_blocks, fn _id, 50 -> {:ok, []} end)
      assert {:ok, []} = Blocks.list(@me, limit: 10_000)
    end

    test "a repository failure is propagated" do
      expect(Messaging.Chat.RepoMock, :list_blocks, fn _id, _limit -> {:error, :timeout} end)

      assert {:error, :timeout} = Blocks.list(@me)
    end
  end

  describe "check_contact/2" do
    defp block_doc(blocker, blocked), do: %{"_id" => blocker <> ":" <> blocked}

    test "no block in either direction is fine, with a single query" do
      expect(Messaging.Chat.RepoMock, :get_blocks, fn ids ->
        assert Enum.sort(ids) == Enum.sort([@me <> ":" <> @other, @other <> ":" <> @me])
        {:ok, []}
      end)

      assert :ok = Blocks.check_contact(@me, @other)
    end

    test "CA3 of DM: if the recipient blocked the sender, it is a generic 'not delivered'" do
      expect(Messaging.Chat.RepoMock, :get_blocks, fn _ids -> {:ok, [block_doc(@other, @me)]} end)

      assert {:error, :dm_not_delivered} = Blocks.check_contact(@me, @other)
    end

    test "if the sender blocked the recipient, the sender is told so" do
      expect(Messaging.Chat.RepoMock, :get_blocks, fn _ids -> {:ok, [block_doc(@me, @other)]} end)

      assert {:error, :user_blocked} = Blocks.check_contact(@me, @other)
    end

    test "when both blocked each other, the sender's own block is what they are told" do
      expect(Messaging.Chat.RepoMock, :get_blocks, fn _ids ->
        {:ok, [block_doc(@other, @me), block_doc(@me, @other)]}
      end)

      assert {:error, :user_blocked} = Blocks.check_contact(@me, @other)
    end

    test "a repository failure is propagated, never treated as 'no block'" do
      expect(Messaging.Chat.RepoMock, :get_blocks, fn _ids -> {:error, :timeout} end)

      assert {:error, :timeout} = Blocks.check_contact(@me, @other)
    end
  end

  describe "blocked_among/2" do
    test "no partners means no query" do
      assert {:ok, set} = Blocks.blocked_among(@me, [])
      assert MapSet.size(set) == 0
    end

    test "returns which of the partners I blocked, in one query" do
      expect(Messaging.Chat.RepoMock, :get_blocks, fn ids ->
        assert Enum.sort(ids) == Enum.sort([@me <> ":" <> @other, @me <> ":" <> @third])
        {:ok, [%{"_id" => @me <> ":" <> @third, "blocked_id" => @third}]}
      end)

      assert {:ok, set} = Blocks.blocked_among(@me, [@other, @third])
      assert MapSet.to_list(set) == [@third]
    end
  end
end
