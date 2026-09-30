defmodule Messaging.Chat.ChannelCacheTest do
  use ExUnit.Case, async: true

  alias Messaging.Chat.ChannelCache

  test "text_channel?/1 is true only for kind text" do
    assert ChannelCache.text_channel?(%ChannelCache{
             channel_id: "c",
             server_id: "s",
             name: "n",
             kind: "text"
           })

    refute ChannelCache.text_channel?(%ChannelCache{
             channel_id: "c",
             server_id: "s",
             name: "n",
             kind: "voice"
           })
  end

  test "from_doc/1 builds a ChannelCache from a Mongo document" do
    doc = %{"_id" => "chan-1", "server_id" => "srv-1", "name" => "general", "kind" => "text"}

    assert ChannelCache.from_doc(doc) == %ChannelCache{
             channel_id: "chan-1",
             server_id: "srv-1",
             name: "general",
             kind: "text"
           }
  end
end
