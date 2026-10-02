defmodule Messaging.Auth.Token do
  @spec user_id(term()) :: {:ok, String.t()} | {:error, :invalid_token}
  def user_id(raw_token) when is_binary(raw_token) do
    with [_header, payload, _signature] <- String.split(raw_token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"sub" => sub}} when is_binary(sub) <- Jason.decode(json),
         trimmed when trimmed != "" <- String.trim(sub) do
      {:ok, trimmed}
    else
      _invalid -> {:error, :invalid_token}
    end
  end

  def user_id(_other), do: {:error, :invalid_token}
end
