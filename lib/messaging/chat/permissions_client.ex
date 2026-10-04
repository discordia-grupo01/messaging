defmodule Messaging.Chat.PermissionsClient do
  @callback can_send_messages?(
              server_id :: String.t(),
              user_id :: String.t(),
              raw_jwt :: String.t()
            ) ::
              {:ok, boolean()} | {:error, term()}

  @callback can_manage_messages?(
              server_id :: String.t(),
              user_id :: String.t(),
              raw_jwt :: String.t()
            ) ::
              {:ok, boolean()} | {:error, term()}

  @callback can_view_channel?(
              server_id :: String.t(),
              user_id :: String.t(),
              raw_jwt :: String.t()
            ) ::
              {:ok, boolean()} | {:error, term()}
end
