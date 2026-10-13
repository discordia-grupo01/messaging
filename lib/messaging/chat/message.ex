defmodule Messaging.Chat.Message do
  @enforce_keys [:id, :channel_id, :server_id, :user_id, :content, :inserted_at]
  defstruct [
    :id,
    :channel_id,
    :server_id,
    :user_id,
    :content,
    :inserted_at,
    :edited_at,
    :deleted_at,
    mentions: [],
    mention_roles: [],
    mention_everyone: false,
    attachments: []
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          channel_id: String.t(),
          server_id: String.t(),
          user_id: String.t(),
          content: String.t(),
          inserted_at: DateTime.t(),
          edited_at: DateTime.t() | nil,
          deleted_at: DateTime.t() | nil,
          mentions: [String.t()],
          mention_roles: [String.t()],
          mention_everyone: boolean(),
          attachments: [map()]
        }

  def from_doc(
        %{
          "_id" => id,
          "channel_id" => channel_id,
          "server_id" => server_id,
          "user_id" => user_id,
          "content" => content,
          "inserted_at" => inserted_at
        } = doc
      ) do
    %__MODULE__{
      id: id,
      channel_id: channel_id,
      server_id: server_id,
      user_id: user_id,
      content: content,
      inserted_at: inserted_at,
      edited_at: Map.get(doc, "edited_at"),
      deleted_at: Map.get(doc, "deleted_at"),
      mentions: Map.get(doc, "mentions") || [],
      mention_roles: Map.get(doc, "mention_roles") || [],
      mention_everyone: Map.get(doc, "mention_everyone") == true,
      attachments: Map.get(doc, "attachments") || []
    }
  end

  @spec mentions?(t()) :: boolean()
  def mentions?(%__MODULE__{mentions: [], mention_roles: [], mention_everyone: false}), do: false
  def mentions?(%__MODULE__{}), do: true

  def to_api(%__MODULE__{} = message) do
    %{
      "id" => message.id,
      "channel_id" => message.channel_id,
      "server_id" => message.server_id,
      "user_id" => message.user_id,
      "content" => message.content,
      "inserted_at" => iso8601_z(message.inserted_at),
      "edited" => message.edited_at != nil,
      "edited_at" => message.edited_at && iso8601_z(message.edited_at),
      "mentions" => message.mentions,
      "mention_roles" => message.mention_roles,
      "mention_everyone" => message.mention_everyone,
      "attachments" => message.attachments
    }
  end

  def to_api(%__MODULE__{} = message, reactions_by_message) when is_map(reactions_by_message),
    do: Map.put(to_api(message), "reactions", Map.get(reactions_by_message, message.id, []))

  def reaction_api(%{message: message, emoji: emoji, count: count}, user_id, action) do
    %{
      "channel_id" => message.channel_id,
      "message_id" => message.id,
      "emoji" => emoji,
      "user_id" => user_id,
      "action" => action,
      "count" => count
    }
  end

  def to_deleted_api(%__MODULE__{} = message) do
    %{
      "id" => message.id,
      "channel_id" => message.channel_id,
      "server_id" => message.server_id,
      "deleted_at" => iso8601_z(message.deleted_at)
    }
  end

  def iso8601_z(%DateTime{} = dt) do
    dt |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_iso8601()
  end
end
