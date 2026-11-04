defmodule Messaging.Premium do
  @moduledoc """
  Whether a user has Premium. billing decides it and `billing.premium_updated`
  feeds the `premium_users` collection, so the state survives restarts and is
  shared by every instance.
  """

  alias Messaging.Chat.Repo

  @spec premium?(String.t()) :: {:ok, boolean()} | {:error, term()}
  def premium?(user_id) when is_binary(user_id) do
    case Repo.impl().premium?(user_id) do
      premium when is_boolean(premium) -> {:ok, premium}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Stores a `billing.premium_updated`. Returns `{:ok, :stale}` when the stored
  version is already the same or newer.
  """
  @spec apply_event(String.t(), boolean(), integer()) ::
          {:ok, :applied | :stale} | {:error, term()}
  def apply_event(user_id, active, version) when is_boolean(active) do
    Repo.impl().apply_premium(user_id, active, version)
  end
end
