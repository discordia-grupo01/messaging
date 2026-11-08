defmodule Messaging.Outbox do
  alias Messaging.Outbox.{Poller, Store}
  alias Messaging.Tracing
  alias Messaging.UUID

  @type entry :: %{
          required(:event) => String.t(),
          required(:topic) => String.t(),
          required(:payload) => map(),
          optional(:apply) => map() | nil,
          optional(:message_id) => String.t() | nil,
          optional(:channel_id) => String.t() | nil,
          optional(:traceparent) => String.t() | nil
        }

  @spec enqueue([entry()]) :: :ok | :duplicate | {:error, term()}
  def enqueue([]), do: :ok

  def enqueue(entries) when is_list(entries) do
    traceparent = Tracing.current_traceparent()

    rows =
      Enum.map(entries, fn entry ->
        entry
        |> Map.put(:id, UUID.generate_v7())
        |> Map.put(:traceparent, traceparent)
      end)

    with :ok <- Store.insert(rows) do
      Poller.kick()
    end
  end
end
