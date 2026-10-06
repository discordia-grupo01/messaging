defmodule Messaging.Chat.UserMention do

  alias Messaging.Chat.Message

  @enforce_keys [:id, :user_id, :message_id, :channel_id, :server_id, :author_id, :inserted_at]
  defstruct [
    :id,
    :user_id,
    :message_id,
    :channel_id,
    :server_id,
    :author_id,
    :inserted_at,
    :read_at,
    message: nil
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          user_id: String.t(),
          message_id: String.t(),
          channel_id: String.t(),
          server_id: String.t(),
          author_id: String.t(),
          inserted_at: DateTime.t(),
          read_at: DateTime.t() | nil,
          message: Message.t() | nil
        }

  @spec id(String.t(), String.t()) :: String.t()
  def id(message_id, user_id), do: message_id <> ":" <> user_id

  @spec new_doc(Message.t(), String.t()) :: map()
  def new_doc(%Message{} = message, user_id) do
    %{
      "_id" => id(message.id, user_id),
      "user_id" => user_id,
      "message_id" => message.id,
      "channel_id" => message.channel_id,
      "server_id" => message.server_id,
      "author_id" => message.user_id,
      "inserted_at" => message.inserted_at,
      "read_at" => nil
    }
  end

  @spec from_doc(map()) :: t()
  def from_doc(doc) do
    %__MODULE__{
      id: doc["_id"],
      user_id: doc["user_id"],
      message_id: doc["message_id"],
      channel_id: doc["channel_id"],
      server_id: doc["server_id"],
      author_id: doc["author_id"],
      inserted_at: doc["inserted_at"],
      read_at: doc["read_at"]
    }
  end

  @spec to_api(t()) :: map()
  def to_api(%__MODULE__{} = mention) do
    %{
      "id" => mention.id,
      "message_id" => mention.message_id,
      "channel_id" => mention.channel_id,
      "server_id" => mention.server_id,
      "author_id" => mention.author_id,
      "inserted_at" => Message.iso8601_z(mention.inserted_at),
      "message" => mention.message && Message.to_api(mention.message)
    }
  end
end
