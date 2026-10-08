defmodule Messaging.Chat.UsersClient.Http do
  @behaviour Messaging.Chat.UsersClient

  alias Messaging.Log

  require Logger

  @impl true
  def user_exists?(user_id, raw_jwt) do
    base_url = Application.fetch_env!(:messaging, :identify_base_url)
    url = "#{base_url}/v1/users/#{URI.encode_www_form(user_id)}"

    opts =
      [
        headers: [{"authorization", "Bearer #{raw_jwt}"}],
        receive_timeout: 2_000,
        retry: false,
        decode_body: false
      ] ++
        plug_opt()

    case Req.get(url, opts) do
      {:ok, %Req.Response{status: 200}} ->
        {:ok, true}

      {:ok, %Req.Response{status: status}} when status in [400, 404] ->
        {:ok, false}

      {:ok, %Req.Response{status: status}} ->
        Logger.error("users_client_unexpected_status", status: status)
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        Logger.error("users_client_request_failed", reason: Log.reason(reason))
        {:error, reason}
    end
  end

  defp plug_opt do
    case Application.get_env(:messaging, :users_http_plug) do
      nil -> []
      plug -> [plug: plug]
    end
  end
end
