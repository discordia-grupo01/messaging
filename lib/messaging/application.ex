defmodule Messaging.Application do
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    mongo_url = Application.fetch_env!(:messaging, :mongo_url)
    Messaging.UUID.init()
    Messaging.Suspension.init()
    Messaging.ServerSuspension.init()
    Messaging.Log.Telemetry.attach()

    Logger.info("service_started",
      version: to_string(Application.spec(:messaging, :vsn)),
      log_level: Logger.level()
    )

    children =
      [
        {Phoenix.PubSub, name: Messaging.PubSub},
        {Mongo,
         Messaging.MongoOptions.build(
           mongo_url,
           Application.fetch_env!(:messaging, :mongo_pool_size)
         )}
      ] ++
        postgres_children() ++
        index_children() ++
        amqp_children() ++
        outbox_children() ++
        cleaner_children() ++ presence_children() ++ [MessagingWeb.Endpoint]

    opts = [strategy: :one_for_one, name: Messaging.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp postgres_children do
    if Application.get_env(:messaging, :start_postgres, true),
      do: [Messaging.Postgres],
      else: []
  end

  defp outbox_children do
    if Application.get_env(:messaging, :start_outbox_poller, true),
      do: [Messaging.Outbox.Poller],
      else: []
  end

  defp presence_children do
    if Application.get_env(:messaging, :start_presence, true),
      do: [
        {Task.Supervisor, name: Messaging.Presence.TaskSupervisor},
        Messaging.Presence.Tracker,
        Messaging.Presence.Sweeper
      ],
      else: []
  end

  defp cleaner_children do
    if Application.get_env(:messaging, :start_attachment_cleaner, true) do
      warn_if_storage_missing()
      [Messaging.Chat.AttachmentCleaner]
    else
      []
    end
  end

  defp warn_if_storage_missing do
    if Application.get_env(:messaging, :storage, Messaging.Storage.Tiered) ==
         Messaging.Storage.Tiered do
      if not Messaging.Storage.Cloudinary.configured?() do
        Logger.warning("attachments_storage_not_configured", hint: "set CLOUDINARY_URL")
      end

      if not Messaging.Storage.Supabase.configured?() do
        Logger.warning("attachments_storage_not_configured",
          hint: "set SUPABASE_URL and SUPABASE_SECRET_KEY"
        )
      end
    end
  end

  defp index_children do
    if Application.get_env(:messaging, :ensure_indexes, true),
      do: [Messaging.Chat.IndexSetup],
      else: []
  end

  defp amqp_children do
    if Application.get_env(:messaging, :start_amqp_consumers, true) do
      rabbitmq_url = Application.fetch_env!(:messaging, :rabbitmq_url)

      [
        {Messaging.Events.ChannelLifecycleConsumer, url: rabbitmq_url},
        {Messaging.Events.BroadcastPublisher, url: rabbitmq_url},
        {Messaging.Events.BroadcastConsumer, url: rabbitmq_url}
      ] ++ admin_events_children(rabbitmq_url) ++ billing_events_children(rabbitmq_url)
    else
      []
    end
  end

  defp admin_events_children(rabbitmq_url) do
    case Application.get_env(:messaging, :admin_events_hmac_secret) do
      secret when secret in [nil, ""] ->
        Logger.error("admin_events_consumer_not_started", reason: "empty_hmac_secret")
        []

      _secret ->
        [{Messaging.Events.AdminEventsConsumer, url: rabbitmq_url}]
    end
  end

  defp billing_events_children(rabbitmq_url) do
    case Application.get_env(:messaging, :billing_events_hmac_secret) do
      secret when secret in [nil, ""] ->
        Logger.error("billing_events_consumer_not_started", reason: "empty_hmac_secret")
        []

      _secret ->
        [{Messaging.Events.BillingEventsConsumer, url: rabbitmq_url}]
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    MessagingWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
