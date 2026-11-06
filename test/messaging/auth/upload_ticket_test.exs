defmodule Messaging.Auth.UploadTicketTest do
  use ExUnit.Case, async: true
  import Mox

  alias Messaging.Auth.SocketTicket
  alias Messaging.Auth.TicketStoreMock
  alias Messaging.Auth.UploadTicket

  setup :verify_on_exit!

  defp stored_id(issue) do
    expect(TicketStoreMock, :put, fn doc ->
      send(self(), {:stored_id, doc["_id"]})
      :ok
    end)

    {:ok, ticket} = issue.("user-1")
    assert_received {:stored_id, id}
    {ticket, id}
  end

  test "issue/1 stores it under a hash, for the configured time" do
    expect(TicketStoreMock, :put, fn doc ->
      assert doc["user_id"] == "user-1"
      assert String.length(doc["_id"]) == 64
      assert DateTime.diff(doc["expires_at"], DateTime.utc_now()) <= UploadTicket.ttl_seconds()
      :ok
    end)

    assert {:ok, _ticket} = UploadTicket.issue("user-1")
  end

  test "redeem/1 finds the ticket it issued" do
    {ticket, id} = stored_id(&UploadTicket.issue/1)

    expect(TicketStoreMock, :take, fn ^id ->
      {:ok, Messaging.AuthFixtures.ticket_doc("user-1")}
    end)

    assert {:ok, %{user_id: "user-1"}} = UploadTicket.redeem(ticket)
  end

  test "an upload ticket cannot be redeemed as a socket ticket, and it is not spent" do
    {ticket, id} = stored_id(&UploadTicket.issue/1)

    expect(TicketStoreMock, :take, fn looked_up ->
      refute looked_up == id
      {:ok, nil}
    end)

    assert {:error, :invalid_ticket} = SocketTicket.redeem(ticket)
  end

  test "a socket ticket cannot be redeemed as an upload ticket, and it is not spent" do
    {ticket, id} = stored_id(&SocketTicket.issue/1)

    expect(TicketStoreMock, :take, fn looked_up ->
      refute looked_up == id
      {:ok, nil}
    end)

    assert {:error, :invalid_ticket} = UploadTicket.redeem(ticket)
  end

  test "redeem/1 rejects a non-binary input without touching the store" do
    assert {:error, :invalid_ticket} = UploadTicket.redeem(nil)
  end
end
