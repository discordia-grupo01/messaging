defmodule Messaging.Log.Telemetry do
  require Logger

  alias Messaging.Log

  @quiet_routes ["/livez", "/readyz"]
  @handler_id "messaging-structured-logs"
  @events [
    [:phoenix, :endpoint, :stop],
    [:phoenix, :error_rendered],
    [:phoenix, :socket_connected],
    [:phoenix, :channel_joined],
    [:phoenix, :channel_handled_in]
  ]

  @spec attach() :: :ok
  def attach do
    :telemetry.detach(@handler_id)
    :ok = :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil)
  end

  @spec handle_event([atom()], map(), map(), term()) :: :ok
  def handle_event([:phoenix, :endpoint, :stop], measurements, %{conn: conn}, _config) do
    route = route(conn)

    Logger.log(request_level(conn.status, route), "http_request",
      method: conn.method,
      route: route,
      status: conn.status,
      duration_ms: duration_ms(measurements),
      user_id: conn.assigns[:user_id]
    )
  end

  def handle_event([:phoenix, :error_rendered], _measurements, metadata, _config) do
    Logger.error("http_error_rendered",
      method: metadata.conn.method,
      route: route(metadata.conn),
      status: metadata.status,
      reason: Log.reason(metadata.reason),
      user_id: metadata.conn.assigns[:user_id]
    )
  end

  def handle_event([:phoenix, :socket_connected], measurements, metadata, _config) do
    Logger.log(socket_level(metadata.result), "socket_connected",
      result: metadata.result,
      transport: metadata.transport,
      duration_ms: duration_ms(measurements)
    )
  end

  def handle_event([:phoenix, :channel_joined], measurements, metadata, _config) do
    Logger.info("channel_joined",
      result: metadata.result,
      topic: metadata.socket.topic,
      user_id: metadata.socket.assigns[:user_id],
      duration_ms: duration_ms(measurements)
    )
  end

  def handle_event([:phoenix, :channel_handled_in], measurements, metadata, _config) do
    Logger.debug("channel_event",
      event: metadata.event,
      topic: metadata.socket.topic,
      user_id: metadata.socket.assigns[:user_id],
      duration_ms: duration_ms(measurements)
    )
  end

  defp route(%Plug.Conn{} = conn) do
    case Phoenix.Router.route_info(MessagingWeb.Router, conn.method, conn.request_path, conn.host) do
      %{route: route} when is_binary(route) -> route
      _unmatched -> "unmatched"
    end
  end

  defp request_level(status, _route) when is_integer(status) and status >= 500, do: :error
  defp request_level(_status, route) when route in @quiet_routes, do: :debug
  defp request_level(_status, _route), do: :info

  defp socket_level(:ok), do: :info
  defp socket_level(_error), do: :warning

  defp duration_ms(%{duration: duration}) do
    duration
    |> System.convert_time_unit(:native, :microsecond)
    |> Kernel./(1000)
    |> Float.round(2)
  end

  defp duration_ms(_measurements), do: nil
end
