defmodule MyAppWeb.MyEntityChannel do
  @moduledoc """
  Igual que un controller, pero para websockets persistentes (Phoenix Channels).
  Nunca accede directo a MyEntity ni al Repo -- siempre pasa por MyApp.MyContext.*
  """
  use Phoenix.Channel

  alias MyApp.MyContext

  @impl true
  def join("my_entity:" <> _id, _params, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_in("create", payload, socket) do
    {:ok, entity} = MyContext.create_my_entity(payload)
    broadcast!(socket, "created", entity)
    {:noreply, socket}
  end
end
