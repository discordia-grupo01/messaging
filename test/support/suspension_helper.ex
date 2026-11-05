defmodule Messaging.SuspensionHelper do
  import Mox

  @doc "Every user and every server is active unless a test stubs it otherwise."
  def stub_active do
    stub(Messaging.Chat.RepoMock, :suspended?, fn _user_id -> false end)
    stub(Messaging.Chat.RepoMock, :server_suspended?, fn _server_id -> false end)
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

  @doc "The server is suspended by the platform staff; every other server is active."
  def stub_server_suspended(server_id) do
    stub(Messaging.Chat.RepoMock, :server_suspended?, fn
      ^server_id -> true
      _other -> false
    end)
  end

  def stub_server_suspension_check_failing(reason \\ :timeout) do
    stub(Messaging.Chat.RepoMock, :server_suspended?, fn _server_id -> {:error, reason} end)
  end
end
