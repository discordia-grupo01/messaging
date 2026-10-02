defmodule Messaging.Auth.TokenTest do
  use ExUnit.Case, async: true

  alias Messaging.Auth.Token
  alias Messaging.AuthFixtures

  test "user_id/1 returns the sub claim without checking the signature" do
    assert {:ok, "user-42"} = Token.user_id(AuthFixtures.token_for("user-42"))
  end

  test "user_id/1 trims the sub claim" do
    assert {:ok, "user-42"} = Token.user_id(AuthFixtures.token_for("  user-42 "))
  end

  test "user_id/1 rejects a token with no sub claim" do
    token = AuthFixtures.token_with_claims(%{"name" => "x"})

    assert {:error, :invalid_token} = Token.user_id(token)
  end

  test "user_id/1 rejects a blank sub claim" do
    assert {:error, :invalid_token} = Token.user_id(AuthFixtures.token_for("   "))
  end

  test "user_id/1 rejects a non-string sub claim" do
    token = AuthFixtures.token_with_claims(%{"sub" => 42})

    assert {:error, :invalid_token} = Token.user_id(token)
  end

  test "user_id/1 rejects garbage" do
    assert {:error, :invalid_token} = Token.user_id("not-a-jwt")
    assert {:error, :invalid_token} = Token.user_id("a.b.c")
  end

  test "user_id/1 rejects a payload that is not JSON" do
    payload = Base.url_encode64("not json", padding: false)

    assert {:error, :invalid_token} = Token.user_id("h." <> payload <> ".s")
  end

  test "user_id/1 rejects a non-binary input" do
    assert {:error, :invalid_token} = Token.user_id(nil)
  end
end
