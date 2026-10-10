defmodule Messaging.Auth.SocketTicketTest do
  use ExUnit.Case, async: true
  import Mox

  alias Messaging.Auth.SocketTicket
  alias Messaging.Auth.TicketStoreMock

  setup :verify_on_exit!

  test "issue/1 stores the user and a short expiry under a hash, never the raw ticket or a token" do
    expect(TicketStoreMock, :put, fn doc ->
      assert doc["user_id"] == "user-1"
      refute Map.has_key?(doc, "raw_jwt")
      assert DateTime.compare(doc["expires_at"], DateTime.utc_now()) == :gt
      assert DateTime.diff(doc["expires_at"], DateTime.utc_now()) <= SocketTicket.ttl_seconds()
      send(self(), {:stored_id, doc["_id"]})
      :ok
    end)

    assert {:ok, ticket} = SocketTicket.issue("user-1")

    assert_received {:stored_id, stored_id}
    refute stored_id == ticket
    assert String.length(stored_id) == 64
  end

  test "issue/1 returns a different ticket every time" do
    stub(TicketStoreMock, :put, fn _doc -> :ok end)

    assert {:ok, first} = SocketTicket.issue("user-1")
    assert {:ok, second} = SocketTicket.issue("user-1")
    refute first == second
  end

  test "issue/1 surfaces a store failure" do
    expect(TicketStoreMock, :put, fn _doc -> {:error, :mongo_down} end)

    assert {:error, :mongo_down} = SocketTicket.issue("user-1")
  end

  test "redeem/1 returns the user for a live ticket, looked up by hash" do
    stub(TicketStoreMock, :put, fn doc ->
      send(self(), {:stored, doc})
      :ok
    end)

    {:ok, ticket} = SocketTicket.issue("user-1")
    assert_received {:stored, doc}

    expect(TicketStoreMock, :take, fn id ->
      assert id == doc["_id"]
      {:ok, doc}
    end)

    assert {:ok, %{user_id: "user-1"}} = SocketTicket.redeem(ticket)
  end

  test "redeem/1 rejects an expired ticket" do
    expect(TicketStoreMock, :take, fn _id ->
      {:ok, Messaging.AuthFixtures.ticket_doc("user-1", ttl: -1)}
    end)

    assert {:error, :invalid_ticket} = SocketTicket.redeem("any")
  end

  test "redeem/1 rejects an unknown or already used ticket" do
    expect(TicketStoreMock, :take, fn _id -> {:ok, nil} end)

    assert {:error, :invalid_ticket} = SocketTicket.redeem("any")
  end

  test "redeem/1 rejects when the store fails" do
    expect(TicketStoreMock, :take, fn _id -> {:error, :mongo_down} end)

    assert {:error, :invalid_ticket} = SocketTicket.redeem("any")
  end

  test "redeem/1 rejects a non-binary input without touching the store" do
    assert {:error, :invalid_ticket} = SocketTicket.redeem(nil)
  end
end
