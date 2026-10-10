defmodule Messaging.Chat.WordFilter do
  @moduledoc """
  Finds a server's banned words in a message. Case and accents don't count
  ("Tónto" matches "tonto") and only whole words do ("película" doesn't match
  "culo"). A banned phrase matches the same words in a row.
  """

  @doc "The banned words (as configured) found in `content`, in list order."
  @spec matches(String.t(), [String.t()]) :: [String.t()]
  def matches(_content, []), do: []

  def matches(content, banned) do
    tokens = tokenize(content)
    Enum.filter(banned, &contains?(tokens, tokenize(&1)))
  end

  defp contains?(_tokens, []), do: false

  defp contains?(tokens, phrase) do
    size = length(phrase)

    tokens
    |> Enum.chunk_every(size, 1, :discard)
    |> Enum.any?(&(&1 == phrase))
  end

  defp tokenize(text) do
    text
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
  end
end
