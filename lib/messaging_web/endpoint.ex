defmodule MessagingWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :messaging

  @dialyzer {:nowarn_function, call: 2}

  socket "/socket", MessagingWeb.UserSocket,
    websocket: true,
    longpoll: false

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug MessagingWeb.Router
end
