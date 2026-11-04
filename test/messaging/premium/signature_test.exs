defmodule Messaging.Premium.SignatureTest do
  use ExUnit.Case, async: true

  alias Messaging.Premium.Signature

  @secret "test-secret"

  # Same vectors as events-contract/billing/vectors_test.go.
  @active %{
    "event_id" => "evt-123",
    "occurred_at" => "2026-11-03T12:30:45.123456Z",
    "user_id" => "user-42",
    "active" => true,
    "premium_until" => "2026-12-03T12:30:45.5Z",
    "renews" => true,
    "version" => 3
  }
  @active_signature "845a3876e1443f855ac3aeae4dbccf92adee5748e42b07888d60f614cf4222a2"

  @never_paid %{
    "event_id" => "evt-124",
    "occurred_at" => "2026-11-03T12:30:45Z",
    "user_id" => "user-42",
    "active" => false,
    "premium_until" => nil,
    "renews" => false,
    "version" => 1
  }
  @never_paid_signature "c30c148b5d9adf70dcf95381f6bbd8302630d4b25a8eac1a06a2e84e3d03ba22"

  test "reproduces the contract's vectors" do
    assert Signature.sign(@active, @secret) == @active_signature
    assert Signature.sign(@never_paid, @secret) == @never_paid_signature
  end

  test "a signed event verifies" do
    assert Signature.verify(Map.put(@active, "signature", @active_signature), @secret)
    assert Signature.verify(Map.put(@never_paid, "signature", @never_paid_signature), @secret)
  end

  test "any change in a signed field breaks the signature" do
    signed = Map.put(@active, "signature", @active_signature)

    for {field, value} <- [
          {"event_id", "evt-2"},
          {"user_id", "user-2"},
          {"active", false},
          {"premium_until", nil},
          {"renews", false},
          {"version", 4},
          {"occurred_at", "2026-11-03T12:30:45.123457Z"}
        ] do
      refute Signature.verify(Map.put(signed, field, value), @secret), "#{field} is not signed"
    end
  end

  test "a wrong or empty secret, or a missing signature, never verifies" do
    signed = Map.put(@active, "signature", @active_signature)

    refute Signature.verify(signed, "other-secret")
    refute Signature.verify(signed, "")
    refute Signature.verify(signed, nil)
    refute Signature.verify(@active, @secret)
    refute Signature.verify(Map.put(@active, "signature", ""), @secret)
    refute Signature.verify(Map.put(@active, "signature", 123), @secret)
  end
end
