defmodule Messaging.MetricsTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  require Record

  @endpoint MessagingWeb.Endpoint

  Record.defrecordp(
    :metric,
    Record.extract(:metric, from_lib: "opentelemetry_experimental/include/otel_metrics.hrl")
  )

  Record.defrecordp(
    :histogram,
    Record.extract(:histogram, from_lib: "opentelemetry_experimental/include/otel_metrics.hrl")
  )

  Record.defrecordp(
    :datapoint,
    :histogram_datapoint,
    Record.extract(:histogram_datapoint,
      from_lib: "opentelemetry_experimental/include/otel_metrics.hrl"
    )
  )

  @uuid "22222222-2222-4222-8222-222222222222"
  @name :"http.server.request.duration"

  setup do
    Process.register(self(), :messaging_metric_sink)
    Messaging.Tracing.attach()
    flush()
    drain()

    on_exit(fn ->
      if Process.whereis(:messaging_metric_sink) == self(),
        do: Process.unregister(:messaging_metric_sink)
    end)

    :ok
  end

  defp flush, do: :otel_meter_server.force_flush()

  defp drain do
    receive do
      {:otel_metric, _} -> drain()
    after
      50 -> :ok
    end
  end

  defp duration_points do
    flush()
    collect([])
  end

  defp collect(acc) do
    receive do
      {:otel_metric, m} when Record.is_record(m, :metric) ->
        if metric(m, :name) == @name do
          collect(acc ++ histogram(metric(m, :data), :datapoints) ++ [{:meta, m}])
        else
          collect(acc)
        end
    after
      200 -> acc
    end
  end

  defp points(list), do: for(dp <- list, Record.is_record(dp, :histogram_datapoint), do: dp)
  defp meta(list), do: for({:meta, m} <- list, do: m)

  defp attrs(dp), do: datapoint(dp, :attributes)

  defp conn(method, path, status) do
    %{Plug.Test.conn(method, path) | status: status}
  end

  defp request(conn, duration_ms) do
    :telemetry.execute([:phoenix, :endpoint, :start], %{}, %{conn: conn})

    :telemetry.execute(
      [:phoenix, :endpoint, :stop],
      %{duration: System.convert_time_unit(duration_ms, :millisecond, :native)},
      %{conn: conn}
    )
  end

  test "records the duration of a request in seconds with method, route and status" do
    request(conn(:get, "/v1/blocks", 200), 250)

    [dp] = duration_points() |> points()

    assert attrs(dp) == %{
             "http.request.method" => "GET",
             "http.route" => "/v1/blocks",
             "http.response.status_code" => 200
           }

    assert datapoint(dp, :count) == 1
    assert_in_delta datapoint(dp, :sum), 0.25, 0.01
  end

  test "describes the instrument with its unit and the buckets in seconds" do
    request(conn(:get, "/v1/blocks", 200), 10)

    list = duration_points()
    [m | _] = meta(list)
    [dp] = points(list)

    assert metric(m, :unit) == :s
    assert datapoint(dp, :explicit_bounds) |> Enum.take(3) == [0.005, 0.01, 0.025]
    assert length(datapoint(dp, :bucket_counts)) == length(datapoint(dp, :explicit_bounds)) + 1
  end

  test "a server error carries error.type so New Relic counts it in the error rate" do
    request(conn(:get, "/v1/blocks", 500), 5)

    [dp] = duration_points() |> points()

    assert attrs(dp)["error.type"] == "500"
    assert attrs(dp)["http.response.status_code"] == 500
  end

  test "a client error is not counted as an error" do
    request(conn(:get, "/v1/blocks", 404), 5)

    [dp] = duration_points() |> points()

    refute Map.has_key?(attrs(dp), "error.type")
  end

  test "requests with the same attributes are aggregated into one data point" do
    request(conn(:get, "/v1/blocks", 200), 10)
    request(conn(:get, "/v1/blocks", 200), 30)
    request(conn(:get, "/v1/blocks", 200), 20)

    [dp] = duration_points() |> points()

    assert datapoint(dp, :count) == 3
    assert_in_delta datapoint(dp, :sum), 0.06, 0.01
  end

  test "different routes and statuses are separate data points" do
    request(conn(:get, "/v1/blocks", 200), 10)
    request(conn(:get, "/v1/channels/#{@uuid}/messages", 200), 10)

    routes = duration_points() |> points() |> Enum.map(&attrs(&1)["http.route"]) |> Enum.sort()

    assert routes == [
             "/v1/blocks",
             "/v1/channels/:channel_id/messages"
           ]
  end

  test "the route is the pattern, never the real path or the query string" do
    request(conn(:get, "/v1/channels/#{@uuid}/messages?ticket=SECRET", 200), 10)
    request(conn(:get, "/no/existe/#{@uuid}", 404), 10)

    dump = duration_points() |> points() |> Enum.map_join(" ", &inspect(attrs(&1)))

    refute dump =~ @uuid
    refute dump =~ "SECRET"
    assert dump =~ "unmatched"
  end

  test "it uses delta temporality: a second collection does not repeat what was already sent" do
    request(conn(:get, "/v1/blocks", 200), 10)
    assert [_one] = duration_points() |> points()

    assert [] = duration_points() |> points()
  end

  test "a stop without measurements records nothing and does not fail" do
    assert :ok =
             Messaging.Tracing.handle_event(
               [:phoenix, :endpoint, :stop],
               %{},
               %{conn: conn(:get, "/v1/blocks", 200)},
               nil
             )

    assert [] = duration_points() |> points()
  end

  test "a request that fails authentication through the real endpoint is recorded with its 401" do
    get(build_conn(), "/v1/blocks")

    [dp] = duration_points() |> points()

    assert attrs(dp) == %{
             "http.request.method" => "GET",
             "http.route" => "/v1/blocks",
             "http.response.status_code" => 401
           }
  end

  test "a request to a route that does not exist through the real endpoint is recorded as unmatched" do
    get(build_conn(), "/nope/#{@uuid}")

    [dp] = duration_points() |> points()

    assert attrs(dp)["http.route"] == "unmatched"
    assert attrs(dp)["http.response.status_code"] == 404
    refute Map.has_key?(attrs(dp), "error.type")
  end
end
