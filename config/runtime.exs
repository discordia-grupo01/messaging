import Config

default_mongo_url =
  if config_env() == :test,
    do: "mongodb://localhost:27017/messaging_test",
    else: "mongodb://localhost:27017/messaging_dev"

log_level =
  case config_env() do
    :dev -> "debug"
    :test -> "warning"
    :prod -> "info"
  end
  |> then(&System.get_env("LOG_LEVEL", &1))
  |> String.downcase()
  |> case do
    "debug" -> :debug
    "info" -> :info
    level when level in ["warn", "warning"] -> :warning
    "error" -> :error
    other -> raise "LOG_LEVEL must be one of debug, info, warning, error (got: #{inspect(other)})"
  end

config :logger, level: log_level

config :messaging,
  mongo_url: System.get_env("MONGO_URL", default_mongo_url),
  mongo_pool_size: String.to_integer(System.get_env("MONGO_POOL_SIZE", "10")),
  rabbitmq_url: System.get_env("RABBITMQ_URL", "amqp://guest:guest@localhost:5672")

# Shared with discordia-admin, which signs the admin.* events. If it is empty the
# consumer of those events does not start: an event that cannot be verified is
# never accepted.
config :messaging, :admin_events_hmac_secret, System.get_env("ADMIN_EVENTS_HMAC_SECRET")

# Shared with discordia-billing, which signs billing.premium_updated. Same rule: if
# it is empty the consumer does not start.
config :messaging, :billing_events_hmac_secret, System.get_env("BILLING_EVENTS_HMAC_SECRET")

config :messaging, :postgres,
  host: System.get_env("DATABASE_HOST", "localhost"),
  port: String.to_integer(System.get_env("DATABASE_PORT", "5432")),
  database: System.get_env("DATABASE_NAME", "messaging"),
  username: System.get_env("DATABASE_USER", "postgres"),
  password: System.get_env("DATABASE_PASSWORD", "postgres"),
  sslmode: System.get_env("DATABASE_SSLMODE", "disable"),
  schema: System.get_env("DATABASE_SCHEMA", "public"),
  pool_size: String.to_integer(System.get_env("DATABASE_POOL_SIZE", "5"))

# Estado de actividad: inactividad tras la que el cliente se reporta ausente, cada cuánto
# escribe cada instancia que sigue viva y cuánto sin escribir para darla por caída.
config :messaging, :presence,
  idle_after_ms: String.to_integer(System.get_env("PRESENCE_IDLE_MS", "300000")),
  heartbeat_ms: String.to_integer(System.get_env("PRESENCE_INSTANCE_HEARTBEAT_MS", "10000")),
  stale_after_ms: String.to_integer(System.get_env("PRESENCE_INSTANCE_STALE_MS", "30000"))

config :messaging, :cloudinary,
  url: System.get_env("CLOUDINARY_URL"),
  folder: System.get_env("CLOUDINARY_FOLDER", "discordia/attachments"),
  api_base: System.get_env("CLOUDINARY_API_BASE_URL", "https://api.cloudinary.com")

if config_env() == :prod do
  allowed_origins =
    System.get_env(
      "CHECK_ORIGIN",
      "https://discordia-g1.vercel.app,https://discordia-g1.duckdns.org"
    )

  config :messaging, MessagingWeb.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT") || "4000")],
    secret_key_base: System.fetch_env!("SECRET_KEY_BASE"),
    check_origin:
      if(allowed_origins == "false",
        do: false,
        else: String.split(allowed_origins, ",", trim: true)
      ),
    server: true

  config :messaging,
    mongo_url: System.fetch_env!("MONGO_URL"),
    rabbitmq_url: System.fetch_env!("RABBITMQ_URL")

  config :messaging, :postgres,
    host: System.fetch_env!("DATABASE_HOST"),
    port: String.to_integer(System.fetch_env!("DATABASE_PORT")),
    database: System.fetch_env!("DATABASE_NAME"),
    username: System.fetch_env!("DATABASE_USER"),
    password: System.fetch_env!("DATABASE_PASSWORD"),
    sslmode: System.get_env("DATABASE_SSLMODE", "require"),
    schema: System.fetch_env!("DATABASE_SCHEMA"),
    pool_size: String.to_integer(System.get_env("DATABASE_POOL_SIZE", "5"))
end
