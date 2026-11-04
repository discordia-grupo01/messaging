defmodule Messaging.Chat.Attachment do
  @max_bytes 10 * 1024 * 1024
  @premium_max_bytes 50 * 1024 * 1024
  @max_per_message 5
  @max_pending_per_user 20
  @max_name_length 100
  @pending_ttl_seconds 24 * 3600

  @enforce_keys [:id, :channel_id, :user_id, :name, :content_type, :size, :path, :url]
  defstruct [
    :id,
    :channel_id,
    :user_id,
    :name,
    :content_type,
    :size,
    :path,
    :url,
    :uploaded_at,
    :message_id
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          channel_id: String.t(),
          user_id: String.t(),
          name: String.t(),
          content_type: String.t(),
          size: non_neg_integer(),
          path: String.t(),
          url: String.t(),
          uploaded_at: DateTime.t() | nil,
          message_id: String.t() | nil
        }

  @type detected :: %{content_type: String.t(), extension: String.t()}
  @type plan :: :free | :premium

  def max_bytes, do: @max_bytes
  def premium_max_bytes, do: @premium_max_bytes
  def max_per_message, do: @max_per_message
  def max_pending_per_user, do: @max_pending_per_user
  def pending_ttl_seconds, do: @pending_ttl_seconds

  @spec max_bytes_for(plan()) :: pos_integer()
  def max_bytes_for(:free), do: @max_bytes
  def max_bytes_for(:premium), do: @premium_max_bytes

  @spec gif?(binary()) :: boolean()
  def gif?(binary), do: match?(%{content_type: "image/gif"}, detect(binary))

  @spec validate(binary(), plan()) ::
          {:ok, detected()} | {:error, :empty_file | :file_too_large | :unsupported_file_type}
  def validate(binary, plan \\ :free)

  def validate(<<>>, _plan), do: {:error, :empty_file}

  def validate(binary, plan) when is_binary(binary) do
    if byte_size(binary) > max_bytes_for(plan) do
      {:error, :file_too_large}
    else
      case {detect(binary), plan} do
        {nil, _plan} -> {:error, :unsupported_file_type}
        {%{content_type: "image/gif"}, :free} -> {:error, :unsupported_file_type}
        {detected, _plan} -> {:ok, detected}
      end
    end
  end

  defp detect(<<"GIF87a", _rest::binary>>), do: %{content_type: "image/gif", extension: "gif"}
  defp detect(<<"GIF89a", _rest::binary>>), do: %{content_type: "image/gif", extension: "gif"}

  defp detect(<<0xFF, 0xD8, 0xFF, _rest::binary>>),
    do: %{content_type: "image/jpeg", extension: "jpg"}

  defp detect(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _rest::binary>>),
    do: %{content_type: "image/png", extension: "png"}

  defp detect(<<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>>),
    do: %{content_type: "image/webp", extension: "webp"}

  defp detect(<<"%PDF-", _rest::binary>>),
    do: %{content_type: "application/pdf", extension: "pdf"}

  defp detect(_other), do: nil

  @spec sanitize_name(term(), String.t()) :: String.t()
  def sanitize_name(name, extension) do
    cleaned =
      name
      |> to_string()
      |> String.split(["/", "\\"])
      |> List.last()
      |> String.replace(~r/[\x00-\x1F\x7F]/u, "")
      |> String.trim()
      |> String.slice(0, @max_name_length)

    if cleaned == "", do: "archivo." <> extension, else: cleaned
  end

  @spec object_key(String.t(), String.t()) :: String.t()
  def object_key(channel_id, id), do: "#{channel_id}/#{id}"

  @spec to_doc(t(), DateTime.t()) :: map()
  def to_doc(%__MODULE__{} = attachment, %DateTime{} = uploaded_at) do
    %{
      "_id" => attachment.id,
      "channel_id" => attachment.channel_id,
      "user_id" => attachment.user_id,
      "name" => attachment.name,
      "content_type" => attachment.content_type,
      "size" => attachment.size,
      "path" => attachment.path,
      "url" => attachment.url,
      "uploaded_at" => uploaded_at,
      "message_id" => nil
    }
  end

  @spec to_api(t() | map()) :: map()
  def to_api(%__MODULE__{} = attachment) do
    %{
      "id" => attachment.id,
      "url" => attachment.url,
      "name" => attachment.name,
      "content_type" => attachment.content_type,
      "size" => attachment.size
    }
  end

  @spec embed(map()) :: map()
  def embed(%{"_id" => id} = doc) do
    %{
      "id" => id,
      "url" => doc["url"],
      "name" => doc["name"],
      "content_type" => doc["content_type"],
      "size" => doc["size"]
    }
  end
end
