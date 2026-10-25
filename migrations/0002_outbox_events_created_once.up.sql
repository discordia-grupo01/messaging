DELETE FROM outbox_events o
 USING outbox_events earlier
 WHERE o.event IN ('new_message', 'new_dm', 'messaging.message_created')
   AND earlier.event = o.event
   AND earlier.topic = o.topic
   AND earlier.message_id = o.message_id
   AND (earlier.created_at, earlier.id) < (o.created_at, o.id);

CREATE UNIQUE INDEX idx_outbox_events_created_once
    ON outbox_events (event, topic, message_id)
    WHERE message_id IS NOT NULL
      AND event IN ('new_message', 'new_dm', 'messaging.message_created');
