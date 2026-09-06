defmodule MyAppWeb.Router do
  @moduledoc "Rutas del servicio: health checks y el ejemplo de context expuesto por REST."
  use Phoenix.Router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", MyAppWeb do
    pipe_through :api

    get "/livez", HealthController, :livez
    get "/readyz", HealthController, :readyz

    get "/my_entities", MyEntityController, :index
    post "/my_entities", MyEntityController, :create
  end
end
