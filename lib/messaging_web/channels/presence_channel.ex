defmodule MessagingWeb.PresenceChannel do
  use Phoenix.Channel
  require Logger

  alias Messaging.Log
  alias Messaging.Presence
  alias Messaging.Suspension
  alias MessagingWeb.ApiError

  @block_cache_ms 30_000

  intercept ["presence_updated", "access_revoked"]

  @impl true
  def join("presence:" <> server_id, _params, socket) do
    user_id = socket.assigns.user_id

    with :ok <- Suspension.ensure_active(user_id),
         {:ok, presences} <- Presence.server_snapshot(user_id, server_id) do
      {:ok, %{"presences" => presences}, assign(socket, server_id: server_id, blocks: %{})}
    else
      {:error, reason} when reason in [:forbidden, :account_suspended, :suspension_unavailable] ->
        {:error, ApiError.payload(reason)}

      {:error, reason} ->
        Logger.error("presence_join_failed",
          server_id: server_id,
          user_id: user_id,
          reason: Log.reason(reason)
        )

        {:error, ApiError.payload(:presence_unavailable)}
    end
  end

  @impl true
  def handle_out("presence_updated", %{"user_id" => user_id} = payload, socket) do
    {visible, socket} = visible?(socket, user_id)
    if visible, do: push(socket, "presence_updated", payload)
    {:noreply, socket}
  end

  def handle_out("access_revoked", %{"user_id" => target} = payload, socket) do
    if is_nil(target) or target == socket.assigns.user_id do
      push(socket, "access_revoked", Map.take(payload, ["server_id", "reason"]))
      {:stop, :shutdown, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_in(_event, _payload, socket),
    do: {:reply, {:error, ApiError.payload(:invalid_payload)}, socket}

  defp visible?(%{assigns: %{user_id: user_id}} = socket, user_id), do: {true, socket}

  defp visible?(socket, other_id) do
    now = System.monotonic_time(:millisecond)

    case Map.get(socket.assigns.blocks, other_id) do
      {blocked, expires_at} when expires_at > now ->
        {not blocked, socket}

      _missing_or_expired ->
        case Presence.blocked?(socket.assigns.user_id, other_id) do
          {:ok, blocked} ->
            blocks = Map.put(socket.assigns.blocks, other_id, {blocked, now + @block_cache_ms})
            {not blocked, assign(socket, :blocks, blocks)}

          {:error, _reason} ->
            {false, socket}
        end
    end
  end
end
