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

  test "messageable?/1 accepts text and dm channels but not voice" do
    for {kind, expected} <- [{"text", true}, {"dm", true}, {"voice", false}] do
      channel = %ChannelCache{channel_id: "c", server_id: nil, name: "", kind: kind}
      assert ChannelCache.messageable?(channel) == expected
    end
  end

  test "from_doc/1 reads a direct conversation without a server" do
    doc = %{
      "_id" => "dm-1",
      "server_id" => nil,
      "name" => "",
      "kind" => "dm",
      "participants" => ["user-a", "user-b"]
    }

    assert %ChannelCache{
             channel_id: "dm-1",
             server_id: nil,
             kind: "dm",
             participants: ["user-a", "user-b"]
           } = ChannelCache.from_doc(doc)
  end

  test "from_doc/1 defaults the fields a server channel never had" do
    doc = %{"_id" => "chan-1", "kind" => "text"}

    assert %ChannelCache{server_id: nil, name: "", participants: []} = ChannelCache.from_doc(doc)
  end
end
