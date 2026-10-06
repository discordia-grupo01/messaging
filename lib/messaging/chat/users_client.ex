defmodule Messaging.Chat.UsersClient do
  @callback user_exists?(user_id :: String.t(), raw_jwt :: String.t()) ::
              {:ok, boolean()} | {:error, term()}
end
