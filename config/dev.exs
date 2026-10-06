import Config

config :messaging, MessagingWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4000],
  secret_key_base: "dev_secret_key_base_at_least_64_bytes_long_only_for_local_development_use",
  debug_errors: true,
  check_origin: false

config :logger, :console, format: "$time [$level] $message $metadata
"
