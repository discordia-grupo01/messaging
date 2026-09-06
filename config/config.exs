import Config

config :my_app, MyAppWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [formats: [json: MyAppWeb.ErrorJSON]],
  pubsub_server: MyApp.PubSub

import_config "#{config_env()}.exs"
