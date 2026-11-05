defmodule Messaging.Chat.Reaction do
  alias Messaging.Chat.CustomEmoji

  @max_emoji_bytes 64
  @max_per_message 20
  @keycap 0x20E3

  @pictographic [
    0x00A9..0x00A9,
    0x00AE..0x00AE,
    0x203C..0x203C,
    0x2049..0x2049,
    0x2122..0x2122,
    0x2139..0x2139,
    0x2194..0x21AA,
    0x231A..0x23FF,
    0x24C2..0x24C2,
    0x25AA..0x25FE,
    0x2600..0x27BF,
    0x2934..0x2935,
    0x2B05..0x2B55,
    0x3030..0x3030,
    0x303D..0x303D,
    0x3297..0x3299,
    0x1F000..0x1FAFF
  ]

  @type summary :: %{String.t() => term()}

  def max_per_message, do: @max_per_message

  @doc """
  A reaction is exactly one emoji: one grapheme whose first code point is
  pictographic, a keycap (1️⃣, #️⃣), or a custom emoji token (`<:name:id>`,
  `<a:name:id>`). Whether a custom emoji can be used is checked separately.
  """
  @spec validate_emoji(term()) :: {:ok, String.t()} | {:error, :invalid_emoji}
  def validate_emoji(emoji) when is_binary(emoji) do
    cond do
      CustomEmoji.token?(emoji) -> {:ok, emoji}
      byte_size(emoji) <= @max_emoji_bytes -> validate_unicode(emoji)
      true -> {:error, :invalid_emoji}
    end
  end

  def validate_emoji(_other), do: {:error, :invalid_emoji}

  defp validate_unicode(emoji) do
    with true <- String.valid?(emoji),
         [^emoji] <- String.graphemes(emoji),
         true <- emoji?(String.to_charlist(emoji)) do
      {:ok, emoji}
    else
      _other -> {:error, :invalid_emoji}
    end
  end

  defp emoji?([first | _rest] = codepoints),
    do: pictographic?(first) or List.last(codepoints) == @keycap

  defp pictographic?(codepoint), do: Enum.any?(@pictographic, &(codepoint in &1))

  @spec id(String.t(), String.t(), String.t()) :: String.t()
  def id(message_id, emoji, user_id), do: "#{message_id}:#{emoji}:#{user_id}"

  @spec new_doc(map(), String.t(), String.t(), DateTime.t()) :: map()
  def new_doc(message, emoji, user_id, at) do
    %{
      "_id" => id(message.id, emoji, user_id),
      "message_id" => message.id,
      "channel_id" => message.channel_id,
      "emoji" => emoji,
      "user_id" => user_id,
      "inserted_at" => at
    }
  end

  @doc """
  Groups reaction docs by message: `%{message_id => [summary]}`, each emoji
  once with its count and whether `viewer_id` is among who reacted, in the
  order the emojis were first used.
  """
  @spec summarize([map()], String.t()) :: %{String.t() => [summary()]}
  def summarize(docs, viewer_id) do
    docs
    |> Enum.sort_by(&{&1["message_id"], DateTime.to_unix(&1["inserted_at"], :microsecond)})
    |> Enum.group_by(& &1["message_id"])
    |> Map.new(fn {message_id, message_docs} ->
      {message_id, summarize_message(message_docs, viewer_id)}
    end)
  end

  defp summarize_message(docs, viewer_id) do
    users_by_emoji = Enum.group_by(docs, & &1["emoji"], & &1["user_id"])

    docs
    |> Enum.map(& &1["emoji"])
    |> Enum.uniq()
    |> Enum.map(fn emoji ->
      users = users_by_emoji[emoji]
      %{"emoji" => emoji, "count" => length(users), "reacted_by_me" => viewer_id in users}
    end)
  end
end
