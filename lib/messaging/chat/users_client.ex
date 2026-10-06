defmodule Messaging.Chat.UsersClient do
  @callback user_exists?(user_id :: String.t(), raw_jwt :: String.t()) ::
              {:ok, boolean()} | {:error, term()}

  @spec verify(String.t(), String.t()) :: :ok | {:error, :not_found | :unavailable}
  def verify(user_id, raw_jwt) do
    case impl().user_exists?(user_id, raw_jwt) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :not_found}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp impl, do: Application.get_env(:messaging, :users_client, Messaging.Chat.UsersClient.Http)
end
