defmodule Messaging.Application do
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    mongo_url = Application.fetch_env!(:messaging, :mongo_url)
    Messaging.UUID.init()
    Messaging.Log.Telemetry.attach()

    Logger.info("service_started",
      version: to_string(Application.spec(:messaging, :vsn)),
      log_level: Logger.level()
    )

    children =
      [
        {Phoenix.PubSub, name: Messaging.PubSub},
        {Mongo, Messaging.MongoOptions.build(mongo_url)}
      ] ++
        index_children() ++
        amqp_children() ++ cleaner_children() ++ [MessagingWeb.Endpoint]

    opts = [strategy: :one_for_one, name: Messaging.Supervisor]
    Supervisor.start_link(children, opts)
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
    storage = Application.get_env(:messaging, :storage, Messaging.Storage.Cloudinary)

    if storage == Messaging.Storage.Cloudinary and not Messaging.Storage.Cloudinary.configured?() do
      Logger.warning("attachments_storage_not_configured", hint: "set CLOUDINARY_URL")
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
      ]
    else
      []
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    MessagingWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
