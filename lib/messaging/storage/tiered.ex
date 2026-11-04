defmodule Messaging.Storage.Tiered do
  @moduledoc """
  Picks where a file lives: up to the free limit in Cloudinary, larger ones
  (Premium only) in Supabase, because Cloudinary Free caps files at 10 MB.
  """

  @behaviour Messaging.Storage

  alias Messaging.Chat.Attachment
  alias Messaging.Storage.{Cloudinary, Supabase}

  @impl true
  def put(key, body, content_type) do
    storage_for(byte_size(body)).put(key, body, content_type)
  end

  @spec storage_for(non_neg_integer()) :: module()
  def storage_for(size) do
    if size > Attachment.max_bytes(), do: Supabase, else: Cloudinary
  end

  @impl true
  def delete(paths) do
    {supabase, cloudinary} = Enum.split_with(paths, &Supabase.owns?/1)

    with :ok <- delete_from(Cloudinary, cloudinary) do
      delete_from(Supabase, supabase)
    end
  end

  defp delete_from(_storage, []), do: :ok
  defp delete_from(storage, paths), do: storage.delete(paths)
end
