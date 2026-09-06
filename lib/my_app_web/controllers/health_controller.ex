defmodule MyAppWeb.HealthController do
  @moduledoc "Endpoints de /livez y /readyz para observabilidad."
  use Phoenix.Controller, formats: [:json]

  # Solo confirma que el proceso esta vivo. No toca la BDD.
  def livez(conn, _params) do
    send_resp(conn, 200, "ok")
  end

  # Confirma que el servicio puede operar (chequear Mongo/broker aca).
  def readyz(conn, _params) do
    # TODO: chequear conexion a Mongo / al broker antes de responder 200
    json(conn, %{status: "ready"})
  end
end
