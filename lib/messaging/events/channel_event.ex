defmodule Messaging.Events.ChannelEvent do
  defmodule ChannelCreated do
    @enforce_keys [:event_id, :occurred_at, :server_id, :channel_id, :name, :kind]
    defstruct [:event_id, :occurred_at, :server_id, :channel_id, :name, :kind]
  end

  defmodule ChannelDeleted do
    @enforce_keys [:event_id, :occurred_at, :server_id, :channel_id]
    defstruct [:event_id, :occurred_at, :server_id, :channel_id]
  end

  defmodule ServerDeleted do
    @enforce_keys [:event_id, :occurred_at, :server_id, :channel_ids]
    defstruct [:event_id, :occurred_at, :server_id, :channel_ids]
  end

  defmodule MemberLeft do
    @enforce_keys [:event_id, :occurred_at, :server_id, :user_id]
    defstruct [:event_id, :occurred_at, :server_id, :user_id]
  end

  @routing_key_channel_created "servers.channel_created"
  @routing_key_channel_deleted "servers.channel_deleted"
  @routing_key_server_deleted "servers.server_deleted"
  @routing_key_member_left "servers.member_left"

  def routing_key_channel_created, do: @routing_key_channel_created
  def routing_key_channel_deleted, do: @routing_key_channel_deleted
  def routing_key_server_deleted, do: @routing_key_server_deleted
  def routing_key_member_left, do: @routing_key_member_left

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

  def parse(@routing_key_server_deleted, payload) do
    case payload do
      %{
        "event_id" => event_id,
        "occurred_at" => occurred_at,
        "server_id" => server_id,
        "channel_ids" => channel_ids
      }
      when is_list(channel_ids) ->
        if Enum.all?(channel_ids, &is_binary/1) do
          {:ok,
           %ServerDeleted{
             event_id: event_id,
             occurred_at: occurred_at,
             server_id: server_id,
             channel_ids: channel_ids
           }}
        else
          {:error, :invalid_payload}
        end

      _other ->
        {:error, :invalid_payload}
    end
  end

  def parse(@routing_key_member_left, payload) do
    case payload do
      %{
        "event_id" => event_id,
        "occurred_at" => occurred_at,
        "server_id" => server_id,
        "user_id" => user_id
      }
      when is_binary(server_id) and is_binary(user_id) ->
        {:ok,
         %MemberLeft{
           event_id: event_id,
           occurred_at: occurred_at,
           server_id: server_id,
           user_id: user_id
         }}

      _other ->
        {:error, :invalid_payload}
    end
  end

  def parse(_other_key, _payload), do: {:error, :unknown_routing_key}
end
