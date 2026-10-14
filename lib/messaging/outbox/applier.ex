defmodule Messaging.Outbox.Applier do
  alias Messaging.Chat.Repo

  @date_fields ~w(inserted_at edited_at deleted_at changed_at)

  @spec apply(map() | nil) :: :ok | {:error, term()}
  def apply(nil), do: :ok

  def apply(%{"op" => "insert_message", "doc" => doc}) when is_map(doc),
    do: Repo.impl().upsert_message(decode_dates(doc))

  def apply(%{
        "op" => "update_message",
        "id" => id,
        "channel_id" => channel_id,
        "fields" => fields
      })
      when is_binary(id) and is_binary(channel_id) and is_map(fields),
      do: Repo.impl().apply_message_update(id, channel_id, decode_dates(fields))

  def apply(%{
        "op" => "delete_message",
        "id" => id,
        "channel_id" => channel_id,
        "deleted_at" => at
      })
      when is_binary(id) and is_binary(channel_id) and is_binary(at) do
    with {:ok, deleted_at} <- parse_date(at),
         {:ok, _doc} <- Repo.impl().delete_message(id, channel_id, deleted_at) do
      :ok
    end
  end

  def apply(other), do: {:error, {:invalid, {:unknown_apply, Map.get(other, "op")}}}

  @spec encode_dates(map()) :: map()
  def encode_dates(map) do
    Map.new(map, fn
      {key, %DateTime{} = value} -> {key, Messaging.Chat.Message.iso8601_z(value)}
      pair -> pair
    end)
  end

  defp decode_dates(map) do
    Map.new(map, fn {key, value} ->
      if key in @date_fields and is_binary(value) do
        {key, value |> parse_date() |> elem(1)}
      else
        {key, value}
      end
    end)
  end

  defp parse_date(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid, :date}}
    end
  end
end
