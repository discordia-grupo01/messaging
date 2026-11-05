defmodule Messaging.Suspension.SignatureServerTest do
  use ExUnit.Case, async: true

  alias Messaging.Suspension.Signature

  # Fixed vectors of events-contract v0.13.1 (admin/vectors_test.go,
  # TestServerSignatureVectors): the Go side computes them and every Elixir port
  # has to reproduce them. They were generated with the secret "test-secret".
  @secret "test-secret"

  @suspended %{
    routing_key: "admin.server_suspended",
    event_id: "evt-123",
    occurred_at: "2026-10-14T12:30:45.123456Z",
    server_id: "server-42",
    version: 3,
    signature: "456c6e2a80ddba4e13664b26baac16f713e2cddea6af70435b522c66a495ca75"
  }
  @whole_second %{
    routing_key: "admin.server_suspended",
    event_id: "evt-124",
    occurred_at: "2026-10-14T12:30:45Z",
    server_id: "server-42",
    version: 4,
    signature: "a80f65168feb3ed64c2fa18290c868006fc4bb4a5445572c1e38d0880ba07468"
  }
  @reactivated %{
    @suspended
    | routing_key: "admin.server_reactivated",
      signature: "b081fcb4de1d6814961bfc77fa1d575058476adac3e057ca39e15dff0d52e30a"
  }
  @user_suspended %{
    routing_key: "admin.user_suspended",
    event_id: "evt-123",
    occurred_at: "2026-10-14T12:30:45.123456Z",
    user_id: "user-42",
    version: 3,
    signature: "4e4e1885838edbda6e1964eedc9452fd5825874a6c280dba7f73a5f6400ba710"
  }

  describe "verify/2 with the vectors of the Go contract" do
    test "accepts a ServerSuspended" do
      assert Signature.verify(@suspended, @secret)
    end

    test "accepts a ServerSuspended whose occurred_at has no fraction" do
      assert Signature.verify(@whole_second, @secret)
    end

    test "accepts a ServerReactivated" do
      assert Signature.verify(@reactivated, @secret)
    end

    test "sign/2 produces exactly what Go produced" do
      assert Signature.sign(Map.delete(@suspended, :signature), @secret) == @suspended.signature
    end

    test "the account events still verify the way they did" do
      assert Signature.verify(@user_suspended, @secret)
    end
  end

  describe "verify/2 rejects" do
    test "another secret, an empty one or none" do
      refute Signature.verify(@suspended, "other-secret")
      refute Signature.verify(@suspended, "")
      refute Signature.verify(@suspended, nil)
    end

    test "a missing, empty or malformed signature" do
      refute Signature.verify(Map.delete(@suspended, :signature), @secret)
      refute Signature.verify(%{@suspended | signature: ""}, @secret)
      refute Signature.verify(%{@suspended | signature: "not-hex"}, @secret)
      refute Signature.verify(%{@suspended | signature: nil}, @secret)
    end

    test "any signed field changed afterwards" do
      refute Signature.verify(%{@suspended | server_id: "server-43"}, @secret)
      refute Signature.verify(%{@suspended | version: 4}, @secret)
      refute Signature.verify(%{@suspended | event_id: "evt-999"}, @secret)
      refute Signature.verify(%{@suspended | occurred_at: "2026-10-14T12:30:46Z"}, @secret)
    end

    test "a suspension replayed as a reactivation, and the other way round" do
      refute Signature.verify(%{@suspended | routing_key: "admin.server_reactivated"}, @secret)
      refute Signature.verify(%{@reactivated | routing_key: "admin.server_suspended"}, @secret)
    end

    test "a deletion request is not accepted with a suspension's signature" do
      refute Signature.verify(
               %{@suspended | routing_key: "admin.server_deletion_requested"},
               @secret
             )
    end

    test "an account event passed off as a server event" do
      replay = %{
        routing_key: "admin.server_suspended",
        event_id: @user_suspended.event_id,
        occurred_at: @user_suspended.occurred_at,
        server_id: @user_suspended.user_id,
        version: @user_suspended.version,
        signature: @user_suspended.signature
      }

      refute Signature.verify(replay, @secret)
    end

    test "an event with no subject or with two" do
      refute Signature.verify(Map.delete(@suspended, :server_id), @secret)
      refute Signature.verify(Map.put(@suspended, :user_id, "user-42"), @secret)
    end

    test "a non-integer version or a non-string server id" do
      refute Signature.verify(%{@suspended | version: "3"}, @secret)
      refute Signature.verify(%{@suspended | server_id: 42}, @secret)
    end
  end
end
