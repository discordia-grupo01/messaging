import Config

config :messaging, MessagingWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [formats: [json: MessagingWeb.ErrorJSON]],
  pubsub_server: Messaging.PubSub

config :logger, :console,
  format: {Messaging.Log.JSONFormatter, :format},
  metadata: [
    :request_id,
    :channel_id,
    :conversation_id,
    :server_id,
    :message_id,
    :user_id,
    :actor_id,
    :author_id,
    :attachment_id,
    :attachments,
    :content_type,
    :size,
    :hint,
    :count,
    :reason,
    :cause,
    :status,
    :permission,
    :allowed,
    :attempt,
    :attempts,
    :retry_in_ms,
    :routing_key,
    :event_id,
    :exchange,
    :queue,
    :channels,
    :users,
    :broadcast_event,
    :method,
    :route,
    :duration_ms,
    :topic,
    :event,
    :result,
    :transport,
    :version,
    :instance_id,
    :log_level,
    :trace_id,
    :span_id
  ]

config :phoenix, :logger, false

config :phoenix,
       :filter_parameters,
       {:keep,
        [
          "id",
          "channel_id",
          "message_id",
          "last_message_id",
          "changes_since",
          "limit",
          "before",
          "after",
          "vsn"
        ]}

import_config "#{config_env()}.exs"
