defmodule Messaging.Events.ChannelEvent do
  defmodule ChannelCreated do
    @enforce_keys [:event_id, :occurred_at, :server_id, :channel_id, :name, :kind]
    defstruct [:event_id, :occurred_at, :server_id, :channel_id, :name, :kind]
  end

  defmodule ChannelDeleted do
    @enforce_keys [:event_id, :occurred_at, :server_id, :channel_id]
    defstruct [:event_id, :occurred_at, :server_id, :channel_id]
  end

  @routing_key_channel_created "servers.channel_created"
  @routing_key_channel_deleted "servers.channel_deleted"

  def routing_key_channel_created, do: @routing_key_channel_created
  def routing_key_channel_deleted, do: @routing_key_channel_deleted

  @spec parse(String.t(), map()) ::
          {:ok, struct()} | {:error, :unknown_routing_key | :invalid_payload}
  def parse(@routing_key_channel_created, payload) do
    case payload do
      %{
        "event_id" => event_id,
        "occurred_at" => occurred_at,
        "server_id" => server_id,
        "channel_id" => channel_id,
        "name" => name,
        "kind" => kind
      } ->
        {:ok,
         %ChannelCreated{
           event_id: event_id,
           occurred_at: occurred_at,
           server_id: server_id,
           channel_id: channel_id,
           name: name,
           kind: kind
         }}

      _other ->
        {:error, :invalid_payload}
    end
  end

  def parse(@routing_key_channel_deleted, payload) do
    case payload do
      %{
        "event_id" => event_id,
        "occurred_at" => occurred_at,
        "server_id" => server_id,
        "channel_id" => channel_id
      } ->
        {:ok,
         %ChannelDeleted{
           event_id: event_id,
           occurred_at: occurred_at,
           server_id: server_id,
           channel_id: channel_id
         }}

      _other ->
        {:error, :invalid_payload}
    end
  end

  def parse(_other_key, _payload), do: {:error, :unknown_routing_key}
end
