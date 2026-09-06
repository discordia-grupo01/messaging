defmodule MyApp.Application do
  @moduledoc "Punto de entrada de la app: arranca el supervisor principal."
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MyAppWeb.Endpoint
      # TODO: agregar aca el supervisor de la conexion a Mongo / cliente del broker
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    MyAppWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
