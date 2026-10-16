defmodule MessagingWeb.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest
      import MessagingWeb.ConnCase

      @endpoint MessagingWeb.Endpoint
    end
  end

  setup _tags do
    Mox.set_mox_private()
    Messaging.OutboxHelper.stub_outbox()
    Messaging.SuspensionHelper.stub_active()
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
