defmodule Messaging.Tracing do
  require Logger
  require OpenTelemetry.Tracer, as: Tracer

  alias OpenTelemetry.Ctx
  alias OpenTelemetry.Span

  @handler_id "messaging-tracing"
  @span_key {__MODULE__, :http_span}

  @spec attach() :: :ok
  def attach do
    :telemetry.detach(@handler_id)

    :ok =
      :telemetry.attach_many(
        @handler_id,
        [[:phoenix, :endpoint, :start], [:phoenix, :endpoint, :stop]],
        &__MODULE__.handle_event/4,
        nil
      )
  end

  @spec handle_event([atom()], map(), map(), term()) :: :ok
  def handle_event([:phoenix, :endpoint, :start], _measurements, %{conn: conn}, _config) do
    parent = :otel_propagator_text_map.extract_to(Ctx.get_current(), conn.req_headers)
    token = Ctx.attach(parent)

    span =
      Tracer.start_span("HTTP #{conn.method}", %{
        kind: :server,
        attributes: %{"http.request.method" => conn.method}
      })

    Tracer.set_current_span(span)
    put_log_metadata(span)
    Process.put(@span_key, {span, token})
    :ok
  end

  def handle_event([:phoenix, :endpoint, :stop], _measurements, %{conn: conn}, _config) do
    case Process.delete(@span_key) do
      {span, token} ->
        route = route(conn)
        Span.update_name(span, "#{conn.method} #{route}")
        Span.set_attribute(span, "http.route", route)
        Span.set_attribute(span, "http.response.status_code", conn.status)
        if error_status?(conn.status), do: Span.set_status(span, OpenTelemetry.status(:error, ""))
        Span.end_span(span)
        Ctx.detach(token)
        :ok

      nil ->
        :ok
    end
  end

  @spec consumer_span(map(), String.t(), (-> result)) :: result when result: var
  def consumer_span(meta, queue, fun) do
    parent = :otel_propagator_text_map.extract_to(Ctx.get_current(), carrier(meta))
    token = Ctx.attach(parent)

    try do
      Tracer.with_span "#{meta.routing_key} process",
                       %{
                         kind: :consumer,
                         attributes: %{
                           "messaging.system" => "rabbitmq",
                           "messaging.destination.name" => queue,
                           "messaging.rabbitmq.destination.routing_key" => meta.routing_key
                         }
                       } do
        put_log_metadata(Tracer.current_span_ctx())
        fun.()
      end
    after
      Logger.metadata(trace_id: nil, span_id: nil)
      Ctx.detach(token)
    end
  end

  @spec mark_outcome(atom()) :: :ok
  def mark_outcome(:retry) do
    Tracer.set_status(OpenTelemetry.status(:error, ""))
    :ok
  end

  def mark_outcome(_outcome), do: :ok

  defp carrier(%{headers: headers}) when is_list(headers) do
    for {name, _type, value} <- headers, is_binary(name), is_binary(value), do: {name, value}
  end

  defp carrier(_meta), do: []

  defp put_log_metadata(span) do
    if OpenTelemetry.Span.is_valid(span) do
      Logger.metadata(trace_id: Span.hex_trace_id(span), span_id: Span.hex_span_id(span))
    end

    :ok
  end

  defp error_status?(status), do: is_integer(status) and status >= 500

  defp route(%Plug.Conn{} = conn) do
    case Phoenix.Router.route_info(MessagingWeb.Router, conn.method, conn.request_path, conn.host) do
      %{route: route} when is_binary(route) -> route
      _unmatched -> "unmatched"
    end
  end
end
