defmodule Messaging.Chat.PermissionsClient.Http do
  @behaviour Messaging.Chat.PermissionsClient

  require Logger

  @impl true
  def can_send_messages?(server_id, user_id, raw_jwt) do
    base_url = Application.fetch_env!(:messaging, :servers_base_url)
    url = "#{base_url}/v1/servers/#{server_id}/members/#{user_id}/permissions"

    opts =
      [headers: [{"authorization", "Bearer #{raw_jwt}"}], receive_timeout: 2_000] ++ plug_opt()

    case Req.get(url, opts) do
      {:ok, %Req.Response{status: 200, body: %{"permissions" => permissions}}} ->
        {:ok, "SEND_MESSAGES" in permissions}

      {:ok, %Req.Response{status: status}} when status in [401, 403, 404] ->
        {:ok, false}

      {:ok, %Req.Response{status: status}} ->
        Logger.warning(
          "messaging: permissions_client unexpected_status status=#{status} server_id=#{server_id}"
        )

        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        Logger.warning(
          "messaging: permissions_client request_failed reason=#{inspect(reason)} server_id=#{server_id}"
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
