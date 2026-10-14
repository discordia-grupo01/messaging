defmodule Messaging.Storage.Cloudinary do
  @behaviour Messaging.Storage

  require Logger

  alias Messaging.Log

  @delete_batch 100
  @default_api_base "https://api.cloudinary.com"
  @default_folder "discordia/attachments"

  @spec configured?() :: boolean()
  def configured?, do: match?({:ok, _config}, config())

  @impl true
  def put(key, body, content_type) do
    with {:ok, config} <- config() do
      public_id = config.folder <> "/" <> key
      timestamp = System.os_time(:second) |> Integer.to_string()

      signed = [
        {"overwrite", "false"},
        {"public_id", public_id},
        {"timestamp", timestamp},
        {"unique_filename", "false"}
      ]

      form =
        [file: {body, filename: "upload", content_type: content_type}, api_key: config.api_key] ++
          [signature: signature(signed, config.api_secret)] ++
          Enum.map(signed, fn {name, value} -> {String.to_atom(name), value} end)

      opts = [form_multipart: form, receive_timeout: 30_000, retry: false] ++ plug_opt()

      case Req.post("#{config.api_base}/v1_1/#{config.cloud_name}/auto/upload", opts) do
        {:ok, %Req.Response{status: 200, body: response}} -> decode_upload(response)
        {:ok, %Req.Response{status: status}} -> upload_failed({:unexpected_status, status})
        {:error, reason} -> upload_failed(reason)
      end
    end
  end

  @impl true
  def delete(paths) do
    with {:ok, config} <- config() do
      paths
      |> Enum.map(&split_path/1)
      |> Enum.group_by(fn {resource_type, _public_id} -> resource_type end, fn {_type, id} ->
        id
      end)
      |> Enum.reduce_while(:ok, fn {resource_type, public_ids}, :ok ->
        case delete_group(config, resource_type, public_ids) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp delete_group(config, resource_type, public_ids) do
    public_ids
    |> Enum.chunk_every(@delete_batch)
    |> Enum.reduce_while(:ok, fn batch, :ok ->
      case delete_batch(config, resource_type, batch) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp delete_batch(config, resource_type, public_ids) do
    opts =
      [
        form: Enum.map(public_ids, &{"public_ids[]", &1}),
        auth: {:basic, "#{config.api_key}:#{config.api_secret}"},
        receive_timeout: 30_000,
        retry: false
      ] ++ plug_opt()

    url = "#{config.api_base}/v1_1/#{config.cloud_name}/resources/#{resource_type}/upload"

    case Req.request([method: :delete, url: url] ++ opts) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status}} ->
        Logger.error("storage_delete_unexpected_status", status: status)
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        Logger.error("storage_delete_failed", reason: Log.reason(reason))
        {:error, reason}
    end
  end

  defp decode_upload(%{"secure_url" => url, "public_id" => public_id, "resource_type" => type})
       when is_binary(url) and is_binary(public_id) and is_binary(type),
       do: {:ok, %{url: url, path: type <> "/" <> public_id}}

  defp decode_upload(_other), do: upload_failed(:invalid_response)

  defp upload_failed(reason) do
    Logger.error("storage_upload_failed", reason: Log.reason(reason))
    {:error, reason}
  end

  defp split_path(path) do
    case String.split(path, "/", parts: 2) do
      [resource_type, public_id] -> {resource_type, public_id}
      [public_id] -> {"image", public_id}
    end
  end

  defp signature(params, api_secret) do
    to_sign =
      params |> Enum.sort() |> Enum.map_join("&", fn {name, value} -> "#{name}=#{value}" end)

    :sha |> :crypto.hash(to_sign <> api_secret) |> Base.encode16(case: :lower)
  end

  defp config do
    settings = Application.get_env(:messaging, :cloudinary, [])

    with url when is_binary(url) and url != "" <- settings[:url],
         %URI{scheme: "cloudinary", host: cloud_name, userinfo: userinfo}
         when is_binary(cloud_name) and cloud_name != "" and is_binary(userinfo) <-
           URI.parse(url),
         [api_key, api_secret] when api_key != "" and api_secret != "" <-
           String.split(userinfo, ":", parts: 2) do
      {:ok,
       %{
         cloud_name: cloud_name,
         api_key: api_key,
         api_secret: api_secret,
         api_base: String.trim_trailing(settings[:api_base] || @default_api_base, "/"),
         folder: String.trim(settings[:folder] || @default_folder, "/")
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
