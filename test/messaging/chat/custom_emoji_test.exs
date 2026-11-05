defmodule Messaging.Chat.CustomEmojiTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  import Mox

  alias Messaging.Chat.{CustomEmoji, RepoMock}

  setup :verify_on_exit!

  @user "user-1"
  @server "11111111-1111-4111-8111-111111111111"
  @other_server "22222222-2222-4222-8222-222222222222"
  @id "2f4e6a8c-1b3d-4f5a-9c7e-8d6b4a2c0e1f"
  @gif_id "3f4e6a8c-1b3d-4f5a-9c7e-8d6b4a2c0e1f"

  defp doc(overrides \\ %{}) do
    Map.merge(
      %{
        "_id" => @id,
        "server_id" => @server,
        "name" => "party",
        "animated" => false,
        "image_url" => "https://cdn.test/party.png"
      },
      overrides
    )
  end

  defp gif, do: doc(%{"_id" => @gif_id, "name" => "dance", "animated" => true})

  defp stub_world(docs, member? \\ true, premium? \\ false) do
    stub(RepoMock, :get_custom_emojis, fn _ids -> {:ok, docs} end)
    stub(RepoMock, :get_member, fn _server, _user -> if member?, do: %{"role_ids" => []} end)
    stub(RepoMock, :premium?, fn _user -> premium? end)
  end

  defp authorize(text, server \\ @server),
    do: CustomEmoji.authorize(@user, CustomEmoji.tokens(text), server)

  describe "tokens/1" do
    test "finds static and animated tokens, each once" do
      text = "hola <:party:#{@id}> y <a:dance:#{@gif_id}> otra <:party:#{@id}>"

      assert [
               %{text: "<:party:" <> _, animated: false, name: "party", id: @id},
               %{animated: true, name: "dance", id: @gif_id}
             ] = CustomEmoji.tokens(text)
    end

    test "ignores what only looks like a token" do
      for text <- [
            "hola",
            ":party:",
            "<:party:not-an-id>",
            "<:a:#{@id}>",
            "<:con espacio:#{@id}>",
            "<@#{@id}>"
          ] do
        assert CustomEmoji.tokens(text) == [], text
      end
    end
  end

  test "token?/1 only accepts one whole token" do
    assert CustomEmoji.token?("<:party:#{@id}>")
    assert CustomEmoji.token?("<a:dance:#{@gif_id}>")
    refute CustomEmoji.token?("x<:party:#{@id}>")
    refute CustomEmoji.token?("<:party:#{@id}> <:party:#{@id}>")
    refute CustomEmoji.token?("<:party:#{@id}>\n")
    refute CustomEmoji.token?("<:party:------------------------------------>")
    refute CustomEmoji.token?("👍")
  end

  test "added_tokens/2 only returns the new ones" do
    old = "<:party:#{@id}>"
    new = "<:party:#{@id}> <a:dance:#{@gif_id}>"

    assert [%{name: "dance"}] = CustomEmoji.added_tokens(new, old)
    assert CustomEmoji.added_tokens(old, new) == []
  end

  describe "authorize/3" do
    test "text without tokens looks nothing up" do
      assert :ok = authorize("hola")
    end

    test "a member uses a static emoji of the same server without Premium" do
      stub_world([doc()])
      assert :ok = authorize("<:party:#{@id}>")
    end

    test "an animated emoji requires Premium" do
      stub_world([gif()])

      assert {:error, :custom_emoji_not_allowed} = authorize("<a:dance:#{@gif_id}>")
    end

    test "with Premium a member uses an animated emoji" do
      stub_world([gif()], true, true)
      assert :ok = authorize("<a:dance:#{@gif_id}>")
    end

    test "an emoji of another server requires Premium" do
      stub_world([doc()])

      assert {:error, :custom_emoji_not_allowed} = authorize("<:party:#{@id}>", @other_server)
    end

    test "with Premium a member uses it in another server" do
      stub_world([doc()], true, true)
      assert :ok = authorize("<:party:#{@id}>", @other_server)
    end

    test "a direct message requires Premium" do
      stub_world([doc()])
      assert {:error, :custom_emoji_not_allowed} = authorize("<:party:#{@id}>", nil)

      stub_world([doc()], true, true)
      assert :ok = authorize("<:party:#{@id}>", nil)
    end

    test "Premium doesn't reach servers where the user isn't a member" do
      stub_world([doc()], false, true)

      assert {:error, :custom_emoji_not_allowed} = authorize("<:party:#{@id}>", @other_server)
    end

    test "being a member is checked in the emoji's server, not the channel's" do
      stub_world([doc()], true, true)

      expect(RepoMock, :get_member, fn @server, @user -> %{"role_ids" => []} end)

      assert :ok = authorize("<:party:#{@id}>", @other_server)
    end

    test "an unknown emoji is rejected" do
      stub_world([])
      assert {:error, :custom_emoji_not_allowed} = authorize("<:party:#{@id}>")
    end

    test "a deleted emoji is rejected, even with Premium" do
      stub_world([doc(%{"deleted" => true})], true, true)
      assert {:error, :custom_emoji_not_allowed} = authorize("<:party:#{@id}>")
    end

    test "the token must match the emoji's name" do
      stub_world([doc()])
      assert {:error, :custom_emoji_not_allowed} = authorize("<:other:#{@id}>")
    end

    test "a GIF can't pass as static to dodge Premium" do
      stub_world([gif()])
      assert {:error, :custom_emoji_not_allowed} = authorize("<:dance:#{@gif_id}>")
    end

    test "one forbidden emoji rejects the whole text" do
      stub_world([doc(), gif()])

      assert {:error, :custom_emoji_not_allowed} =
               authorize("<:party:#{@id}> <a:dance:#{@gif_id}>")
    end

    test "failing to read the state is not a denial" do
      for {function, failing} <- [
            {:get_custom_emojis, fn _ids -> {:error, :down} end},
            {:get_member, fn _server, _user -> {:error, :down} end},
            {:premium?, fn _user -> {:error, :down} end}
          ] do
        stub_world([gif()], true, true)
        stub(RepoMock, function, failing)

        log =
          capture_log(fn ->
            assert {:error, :custom_emojis_unavailable} = authorize("<a:dance:#{@gif_id}>")
          end)

        assert log =~ "custom_emoji_check_failed"
      end
    end
  end

  describe "list/1" do
    test "returns deleted emojis too" do
      expect(RepoMock, :get_custom_emojis, fn [@id] -> {:ok, [doc(%{"deleted" => true})]} end)

      assert {:ok, [%{"id" => @id, "name" => "party", "deleted" => true}]} =
               CustomEmoji.list([@id])
    end

    test "skips invalid and repeated ids" do
      expect(RepoMock, :get_custom_emojis, fn [@id] -> {:ok, []} end)
      assert {:ok, []} = CustomEmoji.list([@id, "nope", @id, %{} |> inspect()])
    end

    test "caps the ids" do
      ids = List.duplicate(@id, CustomEmoji.max_ids() + 1)
      assert {:error, :too_many_custom_emojis} = CustomEmoji.list(ids)
    end

    test "a read failure is reported" do
      expect(RepoMock, :get_custom_emojis, fn _ids -> {:error, :down} end)

      assert capture_log(fn ->
               assert {:error, :custom_emojis_unavailable} = CustomEmoji.list([@id])
             end) =~ "custom_emoji_list_failed"
    end
  end
end
