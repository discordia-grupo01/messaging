defmodule Messaging.Presence do
  require Logger

  alias Messaging.Chat.{Blocks, Repo}
  alias Messaging.Events.DomainEvent
  alias Messaging.Log
  alias Messaging.Outbox
  alias Messaging.Presence.{Notifier, Status, Store}

  @default_idle_after_ms 5 * 60 * 1000
  @max_snapshot_users 100

  @type entry :: %{String.t() => String.t() | non_neg_integer()}

  @spec idle_after_ms() :: pos_integer()
  def idle_after_ms,
    do: Application.get_env(:messaging, :presence, [])[:idle_after_ms] || @default_idle_after_ms

  @spec max_snapshot_users() :: pos_integer()
  def max_snapshot_users, do: @max_snapshot_users

  @spec connect(String.t(), String.t(), String.t()) :: {:ok, Status.choice()} | {:error, term()}
  def connect(user_id, conn_id, instance_id) do
    case change(user_id, {:connect, conn_id, instance_id}) do
      {:ok, :unchanged} -> {:ok, Status.default_choice()}
      {:ok, doc} -> {:ok, Status.manual(doc)}
      {:error, _reason} = error -> error
    end
  end

  @spec disconnect(String.t(), String.t()) :: :ok | {:error, term()}
  def disconnect(user_id, conn_id), do: ok(change(user_id, {:disconnect, conn_id}))

  @doc "A connection reports that its user stopped (or resumed) interacting (CA2)."
  @spec set_activity(String.t(), String.t(), boolean()) :: :ok | {:error, term()}
  def set_activity(user_id, conn_id, idle) when is_boolean(idle),
    do: ok(change(user_id, {:activity, conn_id, idle}))

  @spec set_manual(String.t(), term()) :: :ok | {:error, :invalid_status | term()}
  def set_manual(user_id, choice) do
    if Status.valid_choice?(choice) do
      case change(user_id, {:set_manual, choice}) do
        {:ok, :unchanged} ->
          :ok

        {:ok, doc} ->
          Notifier.own_status_changed(user_id, choice, Status.version(doc))

        {:error, _reason} = error ->
          error
      end
    else
      {:error, :invalid_status}
    end
  end

  @spec drop_instance(String.t(), String.t()) :: :ok | {:error, term()}
  def drop_instance(user_id, instance_id),
    do: ok(change(user_id, {:drop_instance, instance_id}))

  @spec snapshot(String.t(), [String.t()]) :: {:ok, [entry()]} | {:error, term()}
  def snapshot(_viewer_id, []), do: {:ok, []}

  def snapshot(viewer_id, user_ids) do
    with {:ok, docs} <- Store.impl().get_many(user_ids) do
      by_id = Map.new(docs, &{&1["_id"], &1})
      entries = Enum.map(user_ids, &entry(&1, Map.get(by_id, &1)))
      visible = for %{"status" => status} = e <- entries, status != "offline", do: e["user_id"]

      with {:ok, blocked} <- Blocks.blocked_either(viewer_id, visible) do
        {:ok, Enum.map(entries, &hide_blocked(&1, blocked))}
      end
    end
  end

  @spec server_snapshot(String.t(), String.t()) :: {:ok, [entry()]} | {:error, term()}
  def server_snapshot(viewer_id, server_id) do
    with :ok <- ensure_member(server_id, viewer_id),
         {:ok, members} <- Repo.impl().list_members(server_id),
         {:ok, entries} <- snapshot(viewer_id, Enum.map(members, & &1["user_id"])) do
      {:ok, Enum.reject(entries, &(&1["status"] == "offline"))}
    end
  end

  @spec ensure_member(String.t(), String.t()) :: :ok | {:error, :forbidden | term()}
  def ensure_member(server_id, user_id) do
    case Repo.impl().get_member(server_id, user_id) do
      nil -> {:error, :forbidden}
      {:error, _reason} = error -> error
      _member -> :ok
    end
  end

  @spec blocked?(String.t(), String.t()) :: {:ok, boolean()} | {:error, term()}
  def blocked?(viewer_id, user_id) do
    with {:ok, blocked} <- Blocks.blocked_either(viewer_id, [user_id]) do
      {:ok, MapSet.member?(blocked, user_id)}
    end
  end

  defp change(user_id, change) do
    case Store.impl().change(user_id, change) do
      {:ok, {:changed, before}} ->
        after_doc = Status.apply_change(before, change)
        notify_if_visible(user_id, before, after_doc)
        publish_push_state(user_id, before, after_doc)
        {:ok, after_doc}

      {:ok, :unchanged} ->
        {:ok, :unchanged}

      {:error, reason} = error ->
        Logger.error("presence_change_failed",
          user_id: user_id,
          event: elem(change, 0),
          reason: Log.reason(reason)
        )

        error
    end
  end

  defp notify_if_visible(user_id, before, after_doc) do
    status = Status.effective(after_doc)

    if status != Status.effective(before),
      do: Notifier.presence_changed(user_id, status, Status.version(after_doc))
  end

  defp publish_push_state(user_id, before, after_doc) do
    state = Status.push_state(after_doc)

    if state != Status.push_state(before) do
      event =
        DomainEvent.user_presence_changed(
          user_id,
          state.connections,
          state.do_not_disturb,
          Status.version(after_doc)
        )

      case Outbox.enqueue([event]) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("presence_event_enqueue_failed",
            user_id: user_id,
            reason: Log.reason(reason)
          )
      end
    end
  end

  defp entry(user_id, doc),
    do: %{
      "user_id" => user_id,
      "status" => Status.effective(doc),
      "version" => Status.version(doc)
    }

  defp hide_blocked(%{"user_id" => user_id} = entry, blocked) do
    if MapSet.member?(blocked, user_id), do: Map.put(entry, "status", "offline"), else: entry
  end

  defp ok({:ok, _result}), do: :ok
  defp ok({:error, _reason} = error), do: error
end
