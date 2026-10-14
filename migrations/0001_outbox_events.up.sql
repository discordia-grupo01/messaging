CREATE TABLE outbox_events (
    id           UUID PRIMARY KEY,
    event        TEXT NOT NULL,
    topic        TEXT NOT NULL,
    payload      JSONB,
    apply        JSONB,
    message_id   TEXT,
    channel_id   TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    published_at TIMESTAMPTZ,
    attempts     INTEGER NOT NULL DEFAULT 0,
    last_error   TEXT
);

CREATE INDEX idx_outbox_events_pending
    ON outbox_events (created_at, id)
    WHERE published_at IS NULL;

CREATE INDEX idx_outbox_events_pending_message
    ON outbox_events (message_id)
    WHERE published_at IS NULL AND message_id IS NOT NULL;
