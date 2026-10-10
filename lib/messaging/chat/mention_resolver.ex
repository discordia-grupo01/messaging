defmodule Messaging.Chat.MentionResolver do
  alias Messaging.Chat.{ChannelCache, Mentions}

  @callback resolve(ChannelCache.t(), query :: Mentions.query(), actor_id :: String.t()) ::
              {:ok, Mentions.t()} | {:error, term()}

  @spec resolve(ChannelCache.t(), Mentions.query(), String.t()) ::
          {:ok, Mentions.t()} | {:error, :mentions_unavailable}
  def resolve(%ChannelCache{} = channel, query, actor_id) do
    case impl().resolve(channel, query, actor_id) do
      {:ok, %Mentions{}} = ok -> ok
      {:error, _reason} -> {:error, :mentions_unavailable}
    end
  end

  defp impl,
    do: Application.get_env(:messaging, :mention_resolver, Messaging.Chat.MentionResolver.Replica)
end
