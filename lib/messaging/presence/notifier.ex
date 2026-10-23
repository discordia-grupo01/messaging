defmodule Messaging.Presence.Notifier do
  require Logger

  alias Messaging.Events.EventPublisher
  alias Messaging.Log
  alias Messaging.Presence.Audience
  alias Messaging.UUID

  @supervisor Messaging.Presence.TaskSupervisor

  @spec presence_changed(String.t(), String.t(), non_neg_integer()) :: :ok
  def presence_changed(user_id, status, version) do
    run(fn ->
      payload = %{"user_id" => user_id, "status" => status, "version" => version}

      case Audience.topics(user_id) do
        {:ok, topics} ->
          Enum.each(topics, &publish(&1, "presence_updated", payload))

        {:error, reason} ->
          Logger.warning("presence_audience_failed", user_id: user_id, reason: Log.reason(reason))
      end
    end)
  end

  @spec own_status_changed(String.t(), String.t(), non_neg_integer()) :: :ok
  def own_status_changed(user_id, choice, version) do
    run(fn ->
      publish("user:" <> user_id, "own_status_updated", %{
        "status" => choice,
        "version" => version
      })
    end)
  end

  defp publish(topic, event, payload) do
    case EventPublisher.publish_event(UUID.generate(), topic, event, payload) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("presence_publish_failed",
          topic: topic,
          event: event,
          reason: Log.reason(reason)
        )
    end
  end

  defp run(fun) do
    case Process.whereis(@supervisor) do
      nil -> fun.()
      _pid -> {:ok, _task} = Task.Supervisor.start_child(@supervisor, fun)
    end

    :ok
  end
end
