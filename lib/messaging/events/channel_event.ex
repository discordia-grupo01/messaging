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

  defmodule MemberJoined do
    @enforce_keys [:event_id, :occurred_at, :server_id, :user_id]
    defstruct [:event_id, :occurred_at, :server_id, :user_id]
  end

  defmodule MemberLeft do
    @enforce_keys [:event_id, :occurred_at, :server_id, :user_id]
    defstruct [:event_id, :occurred_at, :server_id, :user_id]
  end

  defmodule MemberMuted do
    @enforce_keys [:event_id, :occurred_at, :server_id, :user_id, :muted_by, :until_at, :reason]
    defstruct [:event_id, :occurred_at, :server_id, :user_id, :muted_by, :until_at, :reason]
  end

  defmodule MemberUnmuted do
    @enforce_keys [:event_id, :occurred_at, :server_id, :user_id, :unmuted_by, :reason]
    defstruct [:event_id, :occurred_at, :server_id, :user_id, :unmuted_by, :reason]
  end

  defmodule WordFilterUpdated do
    @enforce_keys [:event_id, :occurred_at, :server_id, :words]
    defstruct [:event_id, :occurred_at, :server_id, :words]
  end

  defmodule ChannelAccessRevoked do
    @enforce_keys [:event_id, :occurred_at, :server_id, :channel_id, :user_ids]
    defstruct [:event_id, :occurred_at, :server_id, :channel_id, :user_ids]
  end

  defmodule RoleUpdated do
    @enforce_keys [:event_id, :occurred_at, :server_id, :role_id, :permissions, :is_everyone]
    defstruct [:event_id, :occurred_at, :server_id, :role_id, :permissions, :is_everyone]
  end

  defmodule RoleDeleted do
    @enforce_keys [:event_id, :occurred_at, :server_id, :role_id]
    defstruct [:event_id, :occurred_at, :server_id, :role_id]
  end

  defmodule MemberRolesUpdated do
    @enforce_keys [:event_id, :occurred_at, :server_id, :user_id, :role_ids]
    defstruct [:event_id, :occurred_at, :server_id, :user_id, :role_ids]
  end

  defmodule ChannelOverridesUpdated do
    @enforce_keys [:event_id, :occurred_at, :server_id, :channel_id, :overrides]
    defstruct [:event_id, :occurred_at, :server_id, :channel_id, :overrides]
  end

  defmodule OwnerUpdated do
    @enforce_keys [:event_id, :occurred_at, :server_id, :owner_id]
    defstruct [:event_id, :occurred_at, :server_id, :owner_id]
  end

  defmodule ProfileUpdated do
    @enforce_keys [:event_id, :occurred_at, :user_id, :version]
    defstruct [:event_id, :occurred_at, :user_id, :version]
  end

  @routing_key_channel_created "servers.channel_created"
  @routing_key_channel_deleted "servers.channel_deleted"
  @routing_key_server_deleted "servers.server_deleted"
  @routing_key_member_joined "servers.member_joined"
  @routing_key_member_left "servers.member_left"
  @routing_key_member_muted "servers.member_muted"
  @routing_key_member_unmuted "servers.member_unmuted"
  @routing_key_word_filter_updated "servers.word_filter_updated"
  @routing_key_channel_access_revoked "servers.channel_access_revoked"
  @routing_key_role_updated "servers.role_updated"
  @routing_key_role_deleted "servers.role_deleted"
  @routing_key_member_roles_updated "servers.member_roles_updated"
  @routing_key_channel_overrides_updated "servers.channel_overrides_updated"
  @routing_key_owner_updated "servers.owner_updated"
  @routing_key_profile_updated "users.profile_updated"

  def routing_key_channel_created, do: @routing_key_channel_created
  def routing_key_channel_deleted, do: @routing_key_channel_deleted
  def routing_key_server_deleted, do: @routing_key_server_deleted
  def routing_key_member_joined, do: @routing_key_member_joined
  def routing_key_member_left, do: @routing_key_member_left
  def routing_key_member_muted, do: @routing_key_member_muted
  def routing_key_member_unmuted, do: @routing_key_member_unmuted
  def routing_key_word_filter_updated, do: @routing_key_word_filter_updated
  def routing_key_channel_access_revoked, do: @routing_key_channel_access_revoked
  def routing_key_role_updated, do: @routing_key_role_updated
  def routing_key_role_deleted, do: @routing_key_role_deleted
  def routing_key_member_roles_updated, do: @routing_key_member_roles_updated
  def routing_key_channel_overrides_updated, do: @routing_key_channel_overrides_updated
  def routing_key_owner_updated, do: @routing_key_owner_updated
  def routing_key_profile_updated, do: @routing_key_profile_updated

  @spec parse(String.t(), map()) ::
          {:ok, struct()} | {:error, :unknown_routing_key | :invalid_payload}
  def parse(routing_key, payload) do
    with {:ok, event} <- do_parse(routing_key, payload),
         {:ok, occurred_at} <- parse_time(event.occurred_at) do
      {:ok, %{event | occurred_at: occurred_at}}
    end
  end

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, :invalid_payload}
    end
  end

  defp parse_time(_other), do: {:error, :invalid_payload}

  defp do_parse(@routing_key_channel_created, payload) do
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

  defp do_parse(@routing_key_channel_deleted, payload) do
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

  defp do_parse(@routing_key_server_deleted, payload) do
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

  defp do_parse(@routing_key_member_joined, payload) do
    case payload do
      %{
        "event_id" => event_id,
        "occurred_at" => occurred_at,
        "server_id" => server_id,
        "user_id" => user_id
      }
      when is_binary(server_id) and is_binary(user_id) ->
        {:ok,
         %MemberJoined{
           event_id: event_id,
           occurred_at: occurred_at,
           server_id: server_id,
           user_id: user_id
         }}

      _other ->
        {:error, :invalid_payload}
    end
  end

  defp do_parse(@routing_key_member_left, payload) do
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

  defp do_parse(@routing_key_member_muted, payload) do
    case payload do
      %{
        "event_id" => event_id,
        "occurred_at" => occurred_at,
        "server_id" => server_id,
        "user_id" => user_id,
        "muted_by" => muted_by,
        "until_at" => until_at,
        "reason" => reason
      }
      when is_binary(server_id) and is_binary(user_id) and is_binary(muted_by) and
             is_binary(reason) ->
        with {:ok, until_at} <- parse_time(until_at) do
          {:ok,
           %MemberMuted{
             event_id: event_id,
             occurred_at: occurred_at,
             server_id: server_id,
             user_id: user_id,
             muted_by: muted_by,
             until_at: until_at,
             reason: reason
           }}
        end

      _other ->
        {:error, :invalid_payload}
    end
  end

  defp do_parse(@routing_key_word_filter_updated, payload) do
    case payload do
      %{
        "event_id" => event_id,
        "occurred_at" => occurred_at,
        "server_id" => server_id,
        "words" => words
      }
      when is_binary(server_id) and is_list(words) ->
        if Enum.all?(words, &is_binary/1),
          do:
            {:ok,
             %WordFilterUpdated{
               event_id: event_id,
               occurred_at: occurred_at,
               server_id: server_id,
               words: words
             }},
          else: {:error, :invalid_payload}

      _other ->
        {:error, :invalid_payload}
    end
  end

  defp do_parse(@routing_key_member_unmuted, payload) do
    case payload do
      %{
        "event_id" => event_id,
        "occurred_at" => occurred_at,
        "server_id" => server_id,
        "user_id" => user_id,
        "unmuted_by" => unmuted_by,
        "reason" => reason
      }
      when is_binary(server_id) and is_binary(user_id) and is_binary(unmuted_by) and
             is_binary(reason) ->
        {:ok,
         %MemberUnmuted{
           event_id: event_id,
           occurred_at: occurred_at,
           server_id: server_id,
           user_id: user_id,
           unmuted_by: unmuted_by,
           reason: reason
         }}

      _other ->
        {:error, :invalid_payload}
    end
  end

  defp do_parse(@routing_key_channel_access_revoked, payload) do
    case payload do
      %{
        "event_id" => event_id,
        "occurred_at" => occurred_at,
        "server_id" => server_id,
        "channel_id" => channel_id,
        "user_ids" => [_first | _rest] = user_ids
      } ->
        if Enum.all?([event_id, server_id, channel_id | user_ids], &non_empty_string?/1) do
          {:ok,
           %ChannelAccessRevoked{
             event_id: event_id,
             occurred_at: occurred_at,
             server_id: server_id,
             channel_id: channel_id,
             user_ids: Enum.uniq(user_ids)
           }}
        else
          {:error, :invalid_payload}
        end

      _other ->
        {:error, :invalid_payload}
    end
  end

  defp do_parse(@routing_key_role_updated, payload) do
    case payload do
      %{
        "event_id" => event_id,
        "occurred_at" => occurred_at,
        "server_id" => server_id,
        "role_id" => role_id,
        "permissions" => permissions,
        "is_everyone" => is_everyone
      }
      when is_boolean(is_everyone) ->
        if strings?([event_id, server_id, role_id]) and string_list?(permissions) do
          {:ok,
           %RoleUpdated{
             event_id: event_id,
             occurred_at: occurred_at,
             server_id: server_id,
             role_id: role_id,
             permissions: Enum.uniq(permissions),
             is_everyone: is_everyone
           }}
        else
          {:error, :invalid_payload}
        end

      _other ->
        {:error, :invalid_payload}
    end
  end

  defp do_parse(@routing_key_role_deleted, payload) do
    case payload do
      %{
        "event_id" => event_id,
        "occurred_at" => occurred_at,
        "server_id" => server_id,
        "role_id" => role_id
      } ->
        if strings?([event_id, server_id, role_id]) do
          {:ok,
           %RoleDeleted{
             event_id: event_id,
             occurred_at: occurred_at,
             server_id: server_id,
             role_id: role_id
           }}
        else
          {:error, :invalid_payload}
        end

      _other ->
        {:error, :invalid_payload}
    end
  end

  defp do_parse(@routing_key_member_roles_updated, payload) do
    case payload do
      %{
        "event_id" => event_id,
        "occurred_at" => occurred_at,
        "server_id" => server_id,
        "user_id" => user_id,
        "role_ids" => role_ids
      } ->
        if strings?([event_id, server_id, user_id]) and string_list?(role_ids) do
          {:ok,
           %MemberRolesUpdated{
             event_id: event_id,
             occurred_at: occurred_at,
             server_id: server_id,
             user_id: user_id,
             role_ids: Enum.uniq(role_ids)
           }}
        else
          {:error, :invalid_payload}
        end

      _other ->
        {:error, :invalid_payload}
    end
  end

  defp do_parse(@routing_key_channel_overrides_updated, payload) do
    with %{
           "event_id" => event_id,
           "occurred_at" => occurred_at,
           "server_id" => server_id,
           "channel_id" => channel_id,
           "overrides" => raw_overrides
         } <- payload,
         true <- strings?([event_id, server_id, channel_id]),
         {:ok, overrides} <- parse_overrides(raw_overrides) do
      {:ok,
       %ChannelOverridesUpdated{
         event_id: event_id,
         occurred_at: occurred_at,
         server_id: server_id,
         channel_id: channel_id,
         overrides: overrides
       }}
    else
      _other -> {:error, :invalid_payload}
    end
  end

  defp do_parse(@routing_key_owner_updated, payload) do
    case payload do
      %{
        "event_id" => event_id,
        "occurred_at" => occurred_at,
        "server_id" => server_id,
        "owner_id" => owner_id
      } ->
        if strings?([event_id, server_id, owner_id]) do
          {:ok,
           %OwnerUpdated{
             event_id: event_id,
             occurred_at: occurred_at,
             server_id: server_id,
             owner_id: owner_id
           }}
        else
          {:error, :invalid_payload}
        end

      _other ->
        {:error, :invalid_payload}
    end
  end

  defp do_parse(@routing_key_profile_updated, payload) do
    case payload do
      %{
        "event_id" => event_id,
        "occurred_at" => occurred_at,
        "user_id" => user_id,
        "version" => version
      }
      when is_integer(version) and version > 0 ->
        if strings?([event_id, user_id]) do
          {:ok,
           %ProfileUpdated{
             event_id: event_id,
             occurred_at: occurred_at,
             user_id: user_id,
             version: version
           }}
        else
          {:error, :invalid_payload}
        end

      _other ->
        {:error, :invalid_payload}
    end
  end

  defp do_parse(_other_key, _payload), do: {:error, :unknown_routing_key}

  defp parse_overrides(raw) when is_list(raw) do
    Enum.reduce_while(raw, {:ok, []}, fn
      %{"role_id" => role_id, "allow" => allow, "deny" => deny}, {:ok, acc} ->
        if strings?([role_id]) and string_list?(allow) and string_list?(deny) do
          override = %{role_id: role_id, allow: Enum.uniq(allow), deny: Enum.uniq(deny)}
          {:cont, {:ok, [override | acc]}}
        else
          {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, overrides} -> {:ok, Enum.reverse(overrides)}
      :error -> :error
    end
  end

  defp parse_overrides(_other), do: :error

  defp strings?(values), do: Enum.all?(values, &non_empty_string?/1)

  defp string_list?(values), do: is_list(values) and Enum.all?(values, &is_binary/1)

  defp non_empty_string?(value), do: is_binary(value) and value != ""
end
