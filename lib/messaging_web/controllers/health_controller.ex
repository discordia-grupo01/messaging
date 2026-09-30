defmodule MessagingWeb.HealthController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  tags ["ops"]

  operation :livez,
    summary: "Liveness -- confirma que el proceso responde, sin tocar Mongo ni el broker",
    responses: [ok: {"ok", "text/plain", %OpenApiSpex.Schema{type: :string}}]

  def livez(conn, _params) do
    send_resp(conn, 200, "ok")
  end

  operation :readyz,
    summary: "Readiness -- confirma que el servicio puede operar (pinguea Mongo)",
    responses: [
      ok: {"ready", "application/json", %OpenApiSpex.Schema{type: :object}},
      service_unavailable:
        {"Mongo no responde", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def readyz(conn, _params) do
    if Messaging.Chat.mongo_ready?() do
      json(conn, %{status: "ready"})
    else
      conn |> put_status(503) |> json(%{status: "unavailable", detail: "mongo"})
    end
  end
end
