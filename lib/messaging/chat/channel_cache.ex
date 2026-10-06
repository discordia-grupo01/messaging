defmodule Messaging.Chat.ChannelCache do
  @enforce_keys [:channel_id, :server_id, :name, :kind]
  defstruct [:channel_id, :server_id, :name, :kind, participants: []]

  @type t :: %__MODULE__{
          channel_id: String.t(),
          server_id: String.t() | nil,
          name: String.t(),
          kind: String.t(),
          participants: [String.t()]
        }

  def text_channel?(%__MODULE__{kind: "text"}), do: true
  def text_channel?(%__MODULE__{}), do: false

  def messageable?(%__MODULE__{kind: kind}), do: kind in ["text", "dm"]

  def from_doc(%{"_id" => channel_id, "kind" => kind} = doc) do
    %__MODULE__{
      channel_id: channel_id,
      server_id: Map.get(doc, "server_id"),
      name: Map.get(doc, "name", ""),
      kind: kind,
      participants: Map.get(doc, "participants", [])
    }
  end
end
