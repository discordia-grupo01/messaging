defmodule Messaging.OutboxHelper do
  import Mox

  def stub_outbox do
    stub(Messaging.Outbox.StoreMock, :insert, fn rows ->
      Enum.each(rows, &MessagingWeb.Endpoint.broadcast!(&1.topic, &1.event, &1.payload))
      :ok
    end)
  end

  def stub_outbox_failing(reason \\ :timeout) do
    stub(Messaging.Outbox.StoreMock, :insert, fn _rows -> {:error, reason} end)
  end
end
