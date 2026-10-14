defmodule Messaging.Outbox do
  alias Messaging.Outbox.{Poller, Store}
  alias Messaging.UUID

  @type entry :: %{
          required(:event) => String.t(),
          required(:topic) => String.t(),
          required(:payload) => map(),
          optional(:apply) => map() | nil,
          optional(:message_id) => String.t() | nil,
          optional(:channel_id) => String.t() | nil
        }

  @spec enqueue([entry()]) :: :ok | {:error, term()}
  def enqueue([]), do: :ok

  def enqueue(entries) when is_list(entries) do
    rows = Enum.map(entries, &Map.put(&1, :id, UUID.generate_v7()))

    with :ok <- Store.insert(rows) do
      Poller.kick()
    end
  end
end
