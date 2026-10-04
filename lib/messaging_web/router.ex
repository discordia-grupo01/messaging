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
    patch "/channels/:channel_id/messages/:message_id", MessageController, :update
    delete "/channels/:channel_id/messages/:message_id", MessageController, :delete
    post "/socket-tickets", SocketTicketController, :create
  end
end
