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
          "Mensajes de canal en tiempo real (envío por WebSocket, historial por REST). " <>
            "Todos los endpoints responden 403 ACCOUNT_SUSPENDED a una cuenta suspendida por el staff " <>
            "y 503 SUSPENSION_UNAVAILABLE si no se pudo verificar su estado. " <>
            "Las rutas de un canal de un servidor suspendido por el staff responden 403 SERVER_SUSPENDED, " <>
            "al owner también; los mensajes se conservan y vuelven al reactivarlo.",
        version: "0.1.0"
      },
      paths: Paths.from_router(MessagingWeb.Router)
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
