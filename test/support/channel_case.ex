defmodule MessagingWeb.ChannelCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import MessagingWeb.ChannelCase

      @endpoint MessagingWeb.Endpoint
    end
  end
end
