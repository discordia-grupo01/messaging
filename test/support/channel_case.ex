defmodule MessagingWeb.ChannelCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import MessagingWeb.ChannelCase

      @endpoint MessagingWeb.Endpoint
    end
  end

  setup _tags do
    Mox.set_mox_private()
    Messaging.OutboxHelper.stub_outbox()
    :ok
  end
end
