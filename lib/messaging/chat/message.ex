defmodule Messaging.Chat.Message do
  @enforce_keys [:id, :channel_id, :server_id, :user_id, :content, :inserted_at]
  defstruct [:id, :channel_id, :server_id, :user_id, :content, :inserted_at]

  @type t :: %__MODULE__{
          id: String.t(),
          channel_id: String.t(),
          server_id: String.t(),
          user_id: String.t(),
          content: String.t(),
          inserted_at: DateTime.t()
        }

  def from_doc(%{
        "_id" => id,
        "channel_id" => channel_id,
        "server_id" => server_id,
        "user_id" => user_id,
        "content" => content,
        "inserted_at" => inserted_at
      }) do
    %__MODULE__{
      id: id,
      channel_id: channel_id,
      server_id: server_id,
      user_id: user_id,
      content: content,
      inserted_at: inserted_at
    }
  end

  def to_api(%__MODULE__{} = message) do
    %{
      "id" => message.id,
      "channel_id" => message.channel_id,
      "server_id" => message.server_id,
      "user_id" => message.user_id,
      "content" => message.content,
      "inserted_at" => iso8601_z(message.inserted_at)
    }
  end

  def iso8601_z(%DateTime{} = dt) do
    dt |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_iso8601()
  end
end
