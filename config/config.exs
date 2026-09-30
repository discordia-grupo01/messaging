import Config

config :messaging, MessagingWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [formats: [json: MessagingWeb.ErrorJSON]],
  pubsub_server: Messaging.PubSub

import_config "#{config_env()}.exs"
