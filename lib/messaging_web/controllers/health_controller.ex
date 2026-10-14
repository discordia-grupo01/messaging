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
    summary: "Readiness -- confirma que el servicio puede operar (pinguea Mongo y Postgres)",
    responses: [
      ok: {"ready", "application/json", %OpenApiSpex.Schema{type: :object}},
      service_unavailable:
        {"Mongo o Postgres no responden", "application/json", %OpenApiSpex.Schema{type: :object}}
    ]

  def readyz(conn, _params) do
    cond do
      not Messaging.Chat.mongo_ready?() ->
        conn |> put_status(503) |> json(%{status: "unavailable", detail: "mongo"})

      Messaging.Outbox.Store.ping() != :ok ->
        conn |> put_status(503) |> json(%{status: "unavailable", detail: "postgres"})

      true ->
        json(conn, %{status: "ready"})
    end
  end
end
