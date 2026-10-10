defmodule Messaging.Chat.PermissionsStore do
  alias Messaging.Chat.ChannelCache

  @callback can_send_messages?(ChannelCache.t(), user_id :: String.t()) ::
              {:ok, boolean()} | {:error, term()}

  @callback can_manage_messages?(ChannelCache.t(), user_id :: String.t()) ::
              {:ok, boolean()} | {:error, term()}

  @callback can_view_channel?(ChannelCache.t(), user_id :: String.t()) ::
              {:ok, boolean()} | {:error, term()}

  @callback can_add_reactions?(ChannelCache.t(), user_id :: String.t()) ::
              {:ok, boolean()} | {:error, term()}
end
