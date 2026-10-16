defmodule Messaging.SuspensionHelper do
  import Mox

  @doc "Every user is active unless a test stubs it otherwise."
  def stub_active do
    stub(Messaging.Chat.RepoMock, :suspended?, fn _user_id -> false end)
  end

  def stub_suspended(user_id) do
    stub(Messaging.Chat.RepoMock, :suspended?, fn
      ^user_id -> true
      _other -> false
    end)
  end

  def stub_suspension_check_failing(reason \\ :timeout) do
    stub(Messaging.Chat.RepoMock, :suspended?, fn _user_id -> {:error, reason} end)
  end
end
