defmodule Messaging.Chat.Conversation do
  alias Messaging.Chat.Message
  alias Messaging.UUID

  @namespace "d15c0d1a-5e0f-4f6e-9a3c-6d6d5f0e7b21"
  @user_id_format ~r/\A[A-Za-z0-9_-]{1,64}\z/

  @enforce_keys [:id, :participants]
  defstruct [
    :id,
    :participants,
    :last_message_at,
    :last_message_user_id,
    :last_message,
    last_read_at: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          participants: [String.t()],
          last_message_at: DateTime.t() | nil,
          last_message_user_id: String.t() | nil,
          last_message: Message.t() | nil,
          last_read_at: %{optional(String.t()) => DateTime.t()}
        }

  @spec id(String.t(), String.t()) :: String.t()
  def id(user_a, user_b) do
    [first, second] = Enum.sort([user_a, user_b])
    UUID.v5(@namespace, "dm:" <> first <> ":" <> second)
  end

  @spec valid_user_id?(term()) :: boolean()
  def valid_user_id?(user_id) when is_binary(user_id), do: Regex.match?(@user_id_format, user_id)
  def valid_user_id?(_other), do: false

  @spec new_doc(String.t(), String.t(), DateTime.t()) :: map()
  def new_doc(user_a, user_b, created_at) do
    %{
      "_id" => id(user_a, user_b),
      "server_id" => nil,
      "name" => "",
      "kind" => "dm",
      "participants" => Enum.sort([user_a, user_b]),
      "created_at" => created_at
    }
  end

  @spec from_doc(map()) :: t()
  def from_doc(%{"_id" => id, "participants" => participants} = doc) do
    %__MODULE__{
      id: id,
      participants: participants,
      last_message_at: Map.get(doc, "last_message_at"),
      last_message_user_id: Map.get(doc, "last_message_user_id"),
      last_read_at: Map.get(doc, "last_read_at") || %{}
    }
  end

  @spec unread?(t(), String.t()) :: boolean()
  def unread?(%__MODULE__{last_message_at: nil}, _user_id), do: false
  def unread?(%__MODULE__{last_message_user_id: user_id}, user_id), do: false

  def unread?(%__MODULE__{last_message_at: at, last_read_at: read}, user_id) do
    case Map.get(read, user_id) do
      nil -> true
      read_at -> DateTime.compare(at, read_at) == :gt
    end
  end

  @spec partner_id(t(), String.t()) :: String.t() | nil
  def partner_id(%__MODULE__{participants: participants}, user_id),
    do: Enum.find(participants, &(&1 != user_id))

  @spec to_api(t(), String.t()) :: map()
  def to_api(%__MODULE__{} = conversation, user_id) do
    %{
      "id" => conversation.id,
      "partner_id" => partner_id(conversation, user_id),
      "unread" => unread?(conversation, user_id),
      "last_message_at" =>
        conversation.last_message_at && Message.iso8601_z(conversation.last_message_at),
      "last_message" => conversation.last_message && Message.to_api(conversation.last_message)
    }
  end
end
