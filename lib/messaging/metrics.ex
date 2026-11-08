defmodule Messaging.Metrics do
  require OpenTelemetryAPIExperimental.Histogram, as: Histogram

  @request_duration :"http.server.request.duration"
  @boundaries [0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1.0, 2.5, 5.0, 7.5, 10.0]

  @spec setup() :: :ok
  def setup do
    Histogram.create(@request_duration, %{
      unit: :s,
      description: "Duration of HTTP server requests.",
      advisory_params: %{explicit_bucket_boundaries: @boundaries}
    })

    :ok
  end

  def record_request(method, route, status, duration_native) do
    seconds = duration_native / System.convert_time_unit(1, :second, :native)

    attributes =
      %{"http.request.method" => method, "http.route" => route}
      |> put_status(status)

    Histogram.record(@request_duration, seconds, attributes)
    :ok
  end

  defp put_status(attributes, status) when is_integer(status) and status >= 500,
    do:
      attributes
      |> Map.put("http.response.status_code", status)
      |> Map.put("error.type", Integer.to_string(status))

  defp put_status(attributes, status) when is_integer(status),
    do: Map.put(attributes, "http.response.status_code", status)

  defp put_status(attributes, _status), do: attributes
end
