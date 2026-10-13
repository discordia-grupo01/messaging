defmodule Messaging.Storage do
  @type stored :: %{url: String.t(), path: String.t()}

  @callback put(key :: String.t(), body :: binary(), content_type :: String.t()) ::
              {:ok, stored()} | {:error, term()}

  @callback delete(paths :: [String.t()]) :: :ok | {:error, term()}

  @spec put(String.t(), binary(), String.t()) :: {:ok, stored()} | {:error, term()}
  def put(key, body, content_type), do: impl().put(key, body, content_type)

  @spec delete([String.t()]) :: :ok | {:error, term()}
  def delete([]), do: :ok
  def delete(paths), do: impl().delete(paths)

  defp impl, do: Application.get_env(:messaging, :storage, Messaging.Storage.Cloudinary)
end
