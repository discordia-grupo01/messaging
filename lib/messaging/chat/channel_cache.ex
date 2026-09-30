defmodule Messaging.Chat.ChannelCache do
  @enforce_keys [:channel_id, :server_id, :name, :kind]
  defstruct [:channel_id, :server_id, :name, :kind]

  @type t :: %__MODULE__{
          channel_id: String.t(),
          server_id: String.t(),
          name: String.t(),
          kind: String.t()
        }

  def text_channel?(%__MODULE__{kind: "text"}), do: true
  def text_channel?(%__MODULE__{}), do: false

  def from_doc(%{"_id" => channel_id, "server_id" => server_id, "name" => name, "kind" => kind}) do
    %__MODULE__{channel_id: channel_id, server_id: server_id, name: name, kind: kind}
  end
end
