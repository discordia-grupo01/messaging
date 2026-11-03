defmodule Messaging.Events.Preview do
  alias Messaging.Chat.Message

  @max_length 140
  @attachment_text "Archivo adjunto"
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
    |> String.replace(@user_token, "@usuario")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp truncate(text) do
    if String.length(text) > @max_length,
      do: text |> String.slice(0, @max_length) |> String.trim_trailing() |> Kernel.<>("…"),
      else: text
  end
end
