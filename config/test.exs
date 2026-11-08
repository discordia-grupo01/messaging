import Config

config :messaging, MessagingWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test_secret_key_base_at_least_64_bytes_long_for_phoenix_dev_only",
  server: false,
  debug_errors: false

config :messaging, :start_amqp_consumers, false
config :messaging, :ensure_indexes, false
config :messaging, :chat_repo, Messaging.Chat.RepoMock
config :messaging, :permissions_store, Messaging.Chat.PermissionsStoreMock
config :messaging, :mention_resolver, Messaging.Chat.MentionResolverMock
config :messaging, :ticket_store, Messaging.Auth.TicketStoreMock
config :messaging, :storage, Messaging.StorageMock
config :messaging, :start_attachment_cleaner, false
config :messaging, :start_postgres, false
config :messaging, :start_outbox_poller, false
config :messaging, :outbox_store, Messaging.Outbox.StoreMock
config :messaging, :event_publisher, Messaging.EventPublisherMock
config :messaging, :broadcaster, Messaging.Events.LocalBroadcaster
config :messaging, :suspension_cache_ttl_ms, 0
config :messaging, :presence_store, Messaging.Presence.StoreMock
config :messaging, :start_presence, false

config :opentelemetry, traces_exporter: :none, processors: [{:otel_simple_processor, %{}}]

config :opentelemetry_experimental,
  readers: [
    %{
      module: :otel_metric_reader,
      config: %{
        exporter: {:otel_metric_exporter_pid, {:otel_metric, :messaging_metric_sink}},
        default_temporality_mapping: %{
          counter: :temporality_delta,
          observable_counter: :temporality_delta,
          histogram: :temporality_delta,
          observable_gauge: :temporality_cumulative,
          updown_counter: :temporality_cumulative,
          observable_updowncounter: :temporality_cumulative
        }
      }
    }
  ]

config :logger, level: :warning
config :logger, :console, colors: [enabled: false]
