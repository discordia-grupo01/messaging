import Config

config :messaging, MessagingWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test_secret_key_base_at_least_64_bytes_long_for_phoenix_dev_only",
  server: false,
  debug_errors: false

config :messaging, :start_amqp_consumers, false
config :messaging, :ensure_indexes, false
config :messaging, :chat_repo, Messaging.Chat.RepoMock
config :messaging, :permissions_client, Messaging.Chat.PermissionsClientMock
config :messaging, :ticket_store, Messaging.Auth.TicketStoreMock
config :messaging, :broadcaster, Messaging.Events.LocalBroadcaster
config :messaging, :permissions_http_plug, {Req.Test, Messaging.Chat.PermissionsClient.Http}

config :logger, level: :warning
