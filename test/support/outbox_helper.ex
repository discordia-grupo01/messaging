defmodule Messaging.OutboxHelper do
  import Mox

  def stub_outbox do
    stub(Messaging.Outbox.StoreMock, :insert, fn rows ->
      Enum.each(rows, &MessagingWeb.Endpoint.broadcast!(&1.topic, &1.event, &1.payload))
      :ok
    end)
  end

  @creation_events [
    "new_message",
    "new_dm",
    "messaging.message_created",
    "messaging.direct_message_created"
  ]

  @doc "Like `stub_outbox/0`, but a creation event already enqueued is a `:duplicate`, as in Postgres."
  def stub_outbox_once do
    {:ok, seen} = Agent.start_link(fn -> MapSet.new() end)

    stub(Messaging.Outbox.StoreMock, :insert, fn rows ->
      keys =
        for row <- rows, row.event in @creation_events, do: {row.event, row.topic, row.message_id}

      if Agent.get(seen, fn seen -> Enum.any?(keys, &MapSet.member?(seen, &1)) end) do
        :duplicate
      else
        Agent.update(seen, &Enum.into(keys, &1))
        Enum.each(rows, &MessagingWeb.Endpoint.broadcast!(&1.topic, &1.event, &1.payload))
        :ok
      end
    end)
  end

  def stub_outbox_failing(reason \\ :timeout) do
    stub(Messaging.Outbox.StoreMock, :insert, fn _rows -> {:error, reason} end)
  end
end
