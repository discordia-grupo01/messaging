import Config

default_mongo_url =
  if config_env() == :test,
    do: "mongodb://localhost:27017/messaging_test",
    else: "mongodb://localhost:27017/messaging_dev"

config :messaging,
  mongo_url: System.get_env("MONGO_URL", default_mongo_url),
  rabbitmq_url: System.get_env("RABBITMQ_URL", "amqp://guest:guest@localhost:5672"),
  jwt_secret: System.get_env("JWT_SECRET", "dev_secret_change_me"),
  servers_base_url: System.get_env("SERVERS_BASE_URL", "http://localhost:8080")

if config_env() == :prod do
  config :messaging, MessagingWeb.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT") || "4000")],
    secret_key_base: System.fetch_env!("SECRET_KEY_BASE"),
    server: true

  config :messaging,
    mongo_url: System.fetch_env!("MONGO_URL"),
    rabbitmq_url: System.fetch_env!("RABBITMQ_URL"),
    jwt_secret: System.fetch_env!("JWT_SECRET"),
    servers_base_url: System.fetch_env!("SERVERS_BASE_URL")
end
