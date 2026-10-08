defmodule Messaging.Chat.MentionsClient.Http do
  @behaviour Messaging.Chat.MentionsClient

  require Logger

  alias Messaging.Chat.Mentions
  alias Messaging.Log

  @impl true
  def resolve(server_id, channel_id, query, raw_jwt) do
    base_url = Application.fetch_env!(:messaging, :servers_base_url)
    url = "#{base_url}/v1/servers/#{URI.encode_www_form(server_id)}/mentions/resolve"

    body = %{
      "channel_id" => channel_id,
      "user_ids" => query.user_ids,
      "role_ids" => query.role_ids,
      "everyone" => query.everyone
    }

    opts =
      [
        json: body,
        headers: [{"authorization", "Bearer #{raw_jwt}"}],
        receive_timeout: 2_000,
        retry: false
      ] ++ plug_opt()

    case Req.post(url, opts) do
      {:ok, %Req.Response{status: 200, body: response}} ->
        decode(response, server_id)

      {:ok, %Req.Response{status: status}} ->
        Logger.error("mentions_client_unexpected_status", status: status, server_id: server_id)

        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        Logger.error("mentions_client_request_failed",
          reason: Log.reason(reason),
          server_id: server_id
        )

        {:error, reason}
    end
  end

  defp decode(
         %{
           "user_ids" => user_ids,
           "role_ids" => role_ids,
           "everyone" => everyone,
           "recipient_ids" => recipient_ids
         },
         _server_id
       )
       when is_list(user_ids) and is_list(role_ids) and is_boolean(everyone) and
              is_list(recipient_ids) do
    {:ok,
     %Mentions{
       user_ids: user_ids,
       role_ids: role_ids,
       everyone: everyone,
       recipient_ids: recipient_ids
     }}
  end

  defp decode(_other, server_id) do
    Logger.error("mentions_client_invalid_body", server_id: server_id)
    {:error, :invalid_body}
  end

  defp plug_opt do
    case Application.get_env(:messaging, :mentions_http_plug) do
      nil -> []
      plug -> [plug: plug]
    end
  end
end
