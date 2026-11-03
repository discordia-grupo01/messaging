defmodule Messaging.Events.Preview do
  alias Messaging.Chat.Message

  @max_length 140
  @attachment_text "Archivo adjunto"
  @mention_width String.length("@usuario")
  @exact_user_token ~r/\A<@[A-Za-z0-9_-]{1,64}>\z/
  @role_token ~r/<@&[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}>/
  @user_token ~r/<@[A-Za-z0-9_-]{1,64}>/

  @spec max_length() :: pos_integer()
  def max_length, do: @max_length

  @spec of(Message.t()) :: String.t() | nil
  def of(%Message{content: content, attachments: attachments}) do
    case content |> normalize() |> truncate() do
      "" when attachments != [] -> @attachment_text
      "" -> nil
      text -> text
    end
  end

  defp normalize(content) do
    content
    |> String.replace(@role_token, "@rol")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp truncate(text) do
    segments = segments(text)

    if visible_length(segments) > @max_length,
      do: cut(segments),
      else: text
  end

  defp segments(text) do
    @user_token
    |> Regex.split(text, include_captures: true, trim: true)
    |> Enum.map(fn piece ->
      if Regex.match?(@exact_user_token, piece), do: {:mention, piece}, else: {:text, piece}
    end)
  end

  defp visible_length(segments) do
    segments |> Enum.map(&width/1) |> Enum.sum()
  end

  defp width({:mention, _token}), do: @mention_width
  defp width({:text, text}), do: String.length(text)

  defp cut(segments) do
    {kept, _left} = Enum.reduce_while(segments, {[], @max_length}, &take/2)

    kept
    |> Enum.reverse()
    |> Enum.join()
    |> String.trim_trailing()
    |> Kernel.<>("…")
  end

  defp take({:mention, token}, {kept, left}) when left >= @mention_width,
    do: {:cont, {[token | kept], left - @mention_width}}

  defp take({:mention, _token}, {kept, left}), do: {:halt, {kept, left}}

  defp take({:text, text}, {kept, left}) do
    length = String.length(text)

    if length <= left,
      do: {:cont, {[text | kept], left - length}},
      else: {:halt, {[String.slice(text, 0, left) | kept], 0}}
  end
end
