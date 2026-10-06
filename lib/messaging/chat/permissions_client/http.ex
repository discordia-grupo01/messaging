defmodule Messaging.Chat.PermissionsClient.Http do
  @behaviour Messaging.Chat.PermissionsClient

  alias Messaging.Log

  require Logger

  @impl true
  def can_send_messages?(channel_id, user_id, raw_jwt),
    do: has_permission?(channel_id, user_id, raw_jwt, "SEND_MESSAGES")

  @impl true
  def can_manage_messages?(channel_id, user_id, raw_jwt),
    do: has_permission?(channel_id, user_id, raw_jwt, "MANAGE_MESSAGES")

  @impl true
  def can_view_channel?(channel_id, user_id, raw_jwt),
    do: has_permission?(channel_id, user_id, raw_jwt, "VIEW_CHANNELS")

  defp has_permission?(channel_id, user_id, raw_jwt, permission) do
    base_url = Application.fetch_env!(:messaging, :servers_base_url)
    url = "#{base_url}/v1/channels/#{channel_id}/members/#{user_id}/permissions"

    opts =
      [headers: [{"authorization", "Bearer #{raw_jwt}"}], receive_timeout: 2_000] ++ plug_opt()

    case Req.get(url, opts) do
      {:ok, %Req.Response{status: 200, body: %{"permissions" => permissions}}} ->
        allowed = permission in permissions

        Logger.debug("permission_checked",
          channel_id: channel_id,
          user_id: user_id,
          permission: permission,
          allowed: allowed
        )

        {:ok, allowed}

      {:ok, %Req.Response{status: status}} when status in [401, 403, 404] ->
        {:ok, false}

      {:ok, %Req.Response{status: status}} ->
        Logger.error("permissions_client_unexpected_status",
          status: status,
          channel_id: channel_id
        )

        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        Logger.error("permissions_client_request_failed",
          reason: Log.reason(reason),
          channel_id: channel_id
        )

        {:error, reason}
    end
  end

  defp plug_opt do
    case Application.get_env(:messaging, :permissions_http_plug) do
      nil -> []
      plug -> [plug: plug]
    end
  end
end
