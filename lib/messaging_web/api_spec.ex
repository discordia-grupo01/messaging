defmodule MessagingWeb.ApiSpec do
  @behaviour OpenApiSpex.OpenApi

  alias OpenApiSpex.{Info, OpenApi, Paths, Server}

  @impl true
  def spec(_opts \\ []) do
    %OpenApi{
      servers: [Server.from_endpoint(MessagingWeb.Endpoint)],
      info: %Info{
        title: "Discordia — Messaging",
        description:
          "Mensajes de canal en tiempo real (envío por WebSocket, historial por REST).",
        version: "0.1.0"
      },
      paths: Paths.from_router(MessagingWeb.Router)
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
