defmodule Messaging.Auth.TokenTest do
  use ExUnit.Case, async: true

  alias Messaging.Auth.Token
  alias Messaging.AuthFixtures

  test "verify_user_id/1 returns the sub claim for a valid token" do
    token = AuthFixtures.token_for("user-42")

    assert {:ok, "user-42"} = Token.verify_user_id(token)
  end

  test "verify_user_id/1 rejects an expired token" do
    token = AuthFixtures.token_for("user-42", ttl: -1)

    assert {:error, _reason} = Token.verify_user_id(token)
  end

  test "verify_user_id/1 rejects garbage" do
    assert {:error, _reason} = Token.verify_user_id("not-a-jwt")
  end

  test "verify_user_id/1 rejects a non-binary input" do
    assert {:error, :invalid_token} = Token.verify_user_id(nil)
  end

  test "verify_user_id/1 rejects a token signed with a different secret" do
    other_signer = Joken.Signer.create("HS256", "a-completely-different-secret")
    {:ok, token, _claims} = Token.generate_and_sign(%{"sub" => "user-42"}, other_signer)

    assert {:error, _reason} = Token.verify_user_id(token)
  end

  test "verify_user_id/1 rejects a token with no sub claim" do
    secret = Application.fetch_env!(:messaging, :jwt_secret)
    signer = Joken.Signer.create("HS256", secret)
    {:ok, token, _claims} = Token.generate_and_sign(%{}, signer)

    assert {:error, :missing_sub} = Token.verify_user_id(token)
  end
end
