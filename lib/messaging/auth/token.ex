defmodule Messaging.Auth.Token do
  use Joken.Config

  @impl true
  def token_config, do: default_claims(skip: [:aud, :iss])

  @spec verify_user_id(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def verify_user_id(raw_token) when is_binary(raw_token) do
    case verify_and_validate(raw_token, signer()) do
      {:ok, %{"sub" => sub}} when is_binary(sub) and sub != "" -> {:ok, sub}
      {:ok, _claims} -> {:error, :missing_sub}
      {:error, reason} -> {:error, reason}
    end
  end

  def verify_user_id(_other), do: {:error, :invalid_token}

  defp signer do
    secret = Application.fetch_env!(:messaging, :jwt_secret)
    Joken.Signer.create("HS256", secret)
  end
end
