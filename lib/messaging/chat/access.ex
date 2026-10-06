defmodule Messaging.Chat.Access do
  alias Messaging.Chat.Access.{Direct, Server}
  alias Messaging.Chat.ChannelCache

  @callback can_view?(ChannelCache.t(), user_id :: String.t(), raw_jwt :: String.t()) ::
              {:ok, boolean()} | {:error, term()}
  @callback can_post?(ChannelCache.t(), user_id :: String.t(), raw_jwt :: String.t()) ::
              {:ok, boolean()} | {:error, term()}
  @callback can_moderate?(ChannelCache.t(), user_id :: String.t(), raw_jwt :: String.t()) ::
              {:ok, boolean()} | {:error, term()}

  @spec for_channel(ChannelCache.t()) :: module()
  def for_channel(%ChannelCache{kind: "dm"}), do: Direct
  def for_channel(%ChannelCache{}), do: Server
end
