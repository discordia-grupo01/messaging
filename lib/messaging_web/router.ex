defmodule MessagingWeb.Router do
  use Phoenix.Router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :authenticated do
    plug MessagingWeb.Plugs.Authenticate
  end

  scope "/", MessagingWeb do
    pipe_through :api

    get "/livez", HealthController, :livez
    get "/readyz", HealthController, :readyz
  end

  scope "/v1", MessagingWeb do
    pipe_through [:api, :authenticated]

    get "/channels/:channel_id/messages", MessageController, :index
  end
end
