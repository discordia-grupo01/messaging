defmodule Messaging.Storage.Supabase do
  @moduledoc """
  Stores files in a public Supabase Storage bucket. The secret key goes only in
  the `apikey` header: Supabase rejects `sb_secret_` keys sent as a Bearer token.
  """

  @behaviour Messaging.Storage

  require Logger

  alias Messaging.Log

  @path_prefix "supabase/"
  @default_bucket "attachments"
  @upload_timeout_ms 120_000
  @delete_timeout_ms 30_000
  @cache_control "max-age=31536000"

  @spec configured?() :: boolean()
  def configured?, do: match?({:ok, _config}, config())

  @spec owns?(String.t()) :: boolean()
  def owns?(path), do: String.starts_with?(path, @path_prefix)

  @impl true
  def put(key, body, content_type) do
    with {:ok, config} <- config() do
      headers =
        auth_headers(config) ++
          [
            {"content-type", content_type},
            {"cache-control", @cache_control},
            {"x-upsert", "false"}
          ]

      opts =
        [body: body, headers: headers, receive_timeout: @upload_timeout_ms, retry: false] ++
          plug_opt()

      case Req.post("#{config.url}/storage/v1/object/#{config.bucket}/#{key}", opts) do
        {:ok, %Req.Response{status: 200}} ->
          {:ok, %{url: public_url(config, key), path: @path_prefix <> key}}

        {:ok, %Req.Response{status: status}} ->
          upload_failed({:unexpected_status, status})

        {:error, reason} ->
          upload_failed(reason)
      end
    end
  end

  @impl true
  def delete(paths) do
    with {:ok, config} <- config() do
      opts =
        [
          method: :delete,
          url: "#{config.url}/storage/v1/object/#{config.bucket}",
          json: %{prefixes: Enum.map(paths, &String.replace_prefix(&1, @path_prefix, ""))},
          headers: auth_headers(config),
          receive_timeout: @delete_timeout_ms,
          retry: false
        ] ++ plug_opt()

      case Req.request(opts) do
        {:ok, %Req.Response{status: 200}} ->
          :ok

        {:ok, %Req.Response{status: status}} ->
          Logger.error("storage_delete_unexpected_status", status: status)
          {:error, {:unexpected_status, status}}

        {:error, reason} ->
          Logger.error("storage_delete_failed", reason: Log.reason(reason))
          {:error, reason}
      end
    end
  end

  defp public_url(config, key),
    do: "#{config.url}/storage/v1/object/public/#{config.bucket}/#{key}"

  defp auth_headers(config), do: [{"apikey", config.secret_key}]

  defp upload_failed(reason) do
    Logger.error("storage_upload_failed", reason: Log.reason(reason))
    {:error, reason}
  end

  defp config do
    settings = Application.get_env(:messaging, :supabase_storage, [])

    with url when is_binary(url) and url != "" <- settings[:url],
         key when is_binary(key) and key != "" <- settings[:secret_key] do
      {:ok,
       %{
         url: String.trim_trailing(url, "/"),
         secret_key: key,
         bucket: settings[:bucket] || @default_bucket
       }}
    else
      _missing -> {:error, :not_configured}
    end
  end

  defp plug_opt do
    case Application.get_env(:messaging, :storage_http_plug) do
      nil -> []
      plug -> [plug: plug]
    end
  end
end
