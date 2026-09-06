import Config

# En test no levantamos el servidor HTTP real, Phoenix.ConnTest lo simula.
config :my_app, MyAppWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test_secret_key_base_at_least_64_bytes_long_for_phoenix_dev_only",
  server: false,
  debug_errors: false

# Menos ruido en la salida de los tests
config :logger, level: :warning
