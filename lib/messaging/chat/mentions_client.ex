defmodule Messaging.Chat.MentionsClient do

  alias Messaging.Chat.Mentions

  @callback resolve(
              server_id :: String.t(),
              channel_id :: String.t(),
              query :: Mentions.query(),
              raw_jwt :: String.t()
            ) :: {:ok, Mentions.t()} | {:error, term()}

  @spec resolve(String.t(), String.t(), Mentions.query(), String.t()) ::
          {:ok, Mentions.t()} | {:error, :mentions_unavailable}
  def resolve(server_id, channel_id, query, raw_jwt) do
    case impl().resolve(server_id, channel_id, query, raw_jwt) do
      {:ok, %Mentions{}} = ok -> ok
      {:error, _reason} -> {:error, :mentions_unavailable}
    end
  end

  defp impl,
    do: Application.get_env(:messaging, :mentions_client, Messaging.Chat.MentionsClient.Http)
end
