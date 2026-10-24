defmodule Messaging.Presence.Audience do
  alias Messaging.Chat.Blocks
  alias Messaging.Presence.Store

  @dm_partner_limit 200

  @spec topics(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def topics(user_id) do
    with {:ok, server_ids} <- Store.impl().member_server_ids(user_id),
         {:ok, partner_ids} <- Store.impl().dm_partner_ids(user_id, @dm_partner_limit),
         {:ok, blocked} <- Blocks.blocked_either(user_id, partner_ids) do
      partners = Enum.reject(partner_ids, &MapSet.member?(blocked, &1))
      {:ok, Enum.map(server_ids, &server_topic/1) ++ Enum.map(partners, &("user:" <> &1))}
    end
  end

  @spec server_topic(String.t()) :: String.t()
  def server_topic(server_id), do: "presence:" <> server_id
end
