defmodule Messaging.Presence.Store do
  alias Messaging.Presence.Status

  @type change_result :: {:ok, {:changed, Status.doc() | nil} | :unchanged} | {:error, term()}

  @callback change(user_id :: String.t(), Status.change()) :: change_result()
  @callback get_many(user_ids :: [String.t()]) :: {:ok, [Status.doc()]} | {:error, term()}
  @callback user_ids_on_instance(instance_id :: String.t()) ::
              {:ok, [String.t()]} | {:error, term()}
  @callback heartbeat(instance_id :: String.t(), at :: DateTime.t()) :: :ok | {:error, term()}
  @callback stale_instances(seen_before :: DateTime.t()) :: {:ok, [String.t()]} | {:error, term()}
  @callback delete_instance(instance_id :: String.t()) :: :ok | {:error, term()}
  @callback member_server_ids(user_id :: String.t()) :: {:ok, [String.t()]} | {:error, term()}
  @callback dm_partner_ids(user_id :: String.t(), limit :: pos_integer()) ::
              {:ok, [String.t()]} | {:error, term()}
  @callback ensure_indexes() :: :ok | {:error, term()}

  @spec impl() :: module()
  def impl, do: Application.get_env(:messaging, :presence_store, Messaging.Presence.Store.Mongo)
end
