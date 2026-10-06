defmodule Messaging.Chat.PermissionsClient do
  @callback can_send_messages?(
              channel_id :: String.t(),
              user_id :: String.t(),
              raw_jwt :: String.t()
            ) ::
              {:ok, boolean()} | {:error, term()}

  @callback can_manage_messages?(
              channel_id :: String.t(),
              user_id :: String.t(),
              raw_jwt :: String.t()
            ) ::
              {:ok, boolean()} | {:error, term()}

  @callback can_view_channel?(
              channel_id :: String.t(),
              user_id :: String.t(),
              raw_jwt :: String.t()
            ) ::
              {:ok, boolean()} | {:error, term()}
end
