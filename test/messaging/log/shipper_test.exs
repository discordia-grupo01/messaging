defmodule Messaging.Log.ShipperTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Messaging.Log.Shipper
  alias Messaging.LogSink

  require Logger

  @api_key "test-ingest-key"

  setup do
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)
    :ok
  end

  defp start_shipper(statuses \\ [], options \\ []) do
    {:ok, url, stop} = LogSink.start(self(), statuses)
    on_exit(stop)

    defaults = [
      url: url,
      api_key: @api_key,
      service: "messaging-test",
      flush_interval_ms: 20,
      base_backoff_ms: 20,
      max_backoff_ms: 40
    ]

    start_supervised!({Shipper, Keyword.merge(defaults, options)})
    url
  end

  defp logs(body), do: body |> Enum.flat_map(& &1["logs"])

  defp receive_logs(timeout \\ 1_000) do
    assert_receive {:sink, request}, timeout
    request
  end

  defp messages(request) do
    request.body
    |> logs()
    |> Enum.map(& &1["message"])
    |> Enum.reject(&String.contains?(&1, "MongoDBConnection"))
  end

  defp receive_request_with(message, timeout \\ 1_000) do
    request = receive_logs(timeout)

    if message in messages(request),
      do: request,
      else: receive_request_with(message, timeout)
  end

  defp receive_entry(message) do
    request = receive_request_with(message)
    {request, Enum.find(logs(request.body), &(&1["message"] == message))}
  end

  defp only(request, prefix),
    do: request |> messages() |> Enum.filter(&String.starts_with?(&1, prefix))

  defp receive_until_delivered(expected, seen) do
    if Enum.all?(expected, &(&1 in seen)),
      do: seen,
      else: receive_until_delivered(expected, seen ++ messages(receive_logs()))
  end

  defp refute_delivered(message, timeout \\ 150) do
    receive do
      {:sink, request} ->
        refute message in messages(request)
        refute_delivered(message, timeout)
    after
      timeout -> :ok
    end
  end

  test "sends the entries to the configured URL gzip-compressed with the api key" do
    start_shipper()

    Logger.info("order_shipped", user_id: "u-1")

    {request, log} = receive_entry("order_shipped")

    assert request.headers["api-key"] == @api_key
    assert request.headers["content-encoding"] == "gzip"
    assert request.headers["content-type"] == "application/json"
    assert [%{"common" => common} | _] = request.body

    assert common["attributes"] == %{
             "service.name" => "messaging-test",
             "entity.name" => "messaging-test"
           }

    assert is_integer(log["timestamp"])
    assert log["attributes"]["level"] == "info"
    assert log["attributes"]["user_id"] == "u-1"
  end

  test "renames the trace and span ids to the names New Relic uses to link logs and traces" do
    start_shipper()

    Logger.metadata(trace_id: "0af7651916cd43dd8448eb211c80319c", span_id: "b7ad6b7169203331")
    on_exit(fn -> Logger.reset_metadata() end)

    Logger.info("with_trace")

    {_request, log} = receive_entry("with_trace")

    assert log["attributes"]["trace.id"] == "0af7651916cd43dd8448eb211c80319c"
    assert log["attributes"]["span.id"] == "b7ad6b7169203331"
    refute Map.has_key?(log["attributes"], "trace_id")
  end

  test "does not send entries without trace" do
    start_shipper()

    Logger.metadata(trace_id: nil, span_id: nil)
    on_exit(fn -> Logger.reset_metadata() end)

    Logger.info("without_trace")

    {_request, log} = receive_entry("without_trace")

    refute Map.has_key?(log["attributes"], "trace.id")
    refute Map.has_key?(log["attributes"], "span.id")
  end

  test "filters sensitive metadata and leaves out metadata outside the whitelist" do
    start_shipper()

    :logger.info("sensitive", %{token: "super-secret", ticket: "t-123", unlisted_field: "x"})

    {request, log} = receive_entry("sensitive")
    raw = Jason.encode!(request.body)

    refute raw =~ "super-secret"
    refute raw =~ "t-123"
    refute raw =~ "unlisted_field"
    assert log["message"] == "sensitive"
  end

  test "groups several entries in one request" do
    start_shipper([], flush_interval_ms: 100)

    for number <- 1..5, do: Logger.info("entry_#{number}")

    request = receive_request_with("entry_1")

    assert only(request, "entry_") == for(number <- 1..5, do: "entry_#{number}")
  end

  test "sends right away when the batch is full without waiting for the interval" do
    start_shipper([], flush_interval_ms: 60_000, max_batch: 3)

    for number <- 1..3, do: Logger.info("full_#{number}")

    request = receive_logs(500)

    assert length(logs(request.body)) == 3
  end

  test "keeps the entries and retries when the server answers with an error" do
    start_shipper([500, 429, 202])

    Logger.info("retried_entry")

    first = receive_logs()
    second = receive_logs()
    third = receive_logs()

    assert "retried_entry" in messages(first)
    assert "retried_entry" in messages(second)
    assert "retried_entry" in messages(third)
    refute_delivered("retried_entry")
  end

  test "keeps the original order when it retries" do
    start_shipper([503, 202], max_batch: 2, flush_interval_ms: 30)

    for number <- 1..4, do: Logger.info("ordered_#{number}")

    expected = for number <- 1..4, do: "ordered_#{number}"
    delivered = receive_until_delivered(expected, [])

    assert delivered |> Enum.uniq() |> Enum.filter(&(&1 in expected)) == expected
  end

  test "discards the batch that the server rejects for good and keeps sending the next ones" do
    start_shipper([400, 202])

    Logger.info("rejected_entry")
    receive_request_with("rejected_entry")

    Logger.info("next_entry")
    second = receive_request_with("next_entry")

    refute "rejected_entry" in messages(second)
    refute_delivered("rejected_entry")
  end

  test "never sends its own warnings, so a failing server does not feed itself" do
    start_shipper([500, 500, 202])

    Logger.info("only_entry")

    requests = for _ <- 1..3, do: receive_logs()
    sent = requests |> Enum.flat_map(&messages/1) |> Enum.uniq()

    assert "only_entry" in sent
    refute "log_shipping_failed" in sent
    refute_delivered("log_shipping_failed")
    refute_delivered("log_shipping_recovered")
  end

  test "the queue is bounded: when it overflows it drops the oldest entries" do
    url = "http://127.0.0.1:1/unreachable"

    start_supervised!(
      {Shipper,
       url: url,
       api_key: @api_key,
       max_queue: 3,
       max_batch: 100,
       flush_interval_ms: 60_000,
       base_backoff_ms: 60_000,
       max_backoff_ms: 60_000}
    )

    for number <- 1..5, do: Logger.info("queued_#{number}")

    state = :sys.get_state(Shipper)
    kept = state.queue |> :queue.to_list() |> Enum.map(& &1.message)

    assert state.size == 3
    assert state.dropped == 2
    assert kept == ["queued_3", "queued_4", "queued_5"]
  end

  test "an unreachable server does not break the caller" do
    start_supervised!(
      {Shipper,
       url: "http://127.0.0.1:1/unreachable",
       api_key: @api_key,
       flush_interval_ms: 20,
       base_backoff_ms: 20,
       max_backoff_ms: 40}
    )

    assert :ok = Logger.info("sent_into_the_void")
    Process.sleep(100)
    assert Process.alive?(Process.whereis(Shipper))
  end

  test "when it stops it sends what was pending" do
    start_shipper([], flush_interval_ms: 60_000)

    Logger.info("pending_at_shutdown")
    :ok = stop_supervised(Shipper)

    receive_request_with("pending_at_shutdown")
  end

  test "once stopped it no longer collects logs" do
    start_shipper()
    :ok = stop_supervised(Shipper)

    assert :ok = Logger.info("after_shutdown")
    assert {:error, {:not_found, _}} = :logger.get_handler_config(:messaging_log_shipper)
  end

  test "reports with a custom callback are sent as text" do
    start_shipper()

    :logger.info(%{event: :custom}, %{report_cb: fn report -> {~c"report ~p", [report.event]} end})

    receive_request_with("report custom")
  end

  test "Erlang-style messages are sent formatted" do
    start_shipper()

    :logger.info(~c"formatted ~p and ~s", [42, "text"])

    receive_request_with("formatted 42 and text")
  end

  test "the api key never ends up in what is sent" do
    start_shipper()

    Logger.info("check_key")

    refute Jason.encode!(receive_request_with("check_key").body) =~ @api_key
  end
end
