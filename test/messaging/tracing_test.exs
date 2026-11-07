defmodule Messaging.TracingTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Record

  Record.defrecordp(
    :span,
    Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  @trace_id "4bf92f3577b34da6a3ce929d0e0e4736"
  @parent_span_id "00f067aa0ba902b7"
  @traceparent "00-#{@trace_id}-#{@parent_span_id}-01"
  @uuid "22222222-2222-4222-8222-222222222222"

  setup do
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    Messaging.Log.Telemetry.attach()
    Messaging.Tracing.attach()
    previous = Logger.level()
    Logger.configure(level: :debug)

    on_exit(fn ->
      Logger.configure(level: previous)
      Logger.metadata(trace_id: nil, span_id: nil)
    end)

    :ok
  end

  defp hex(id, digits),
    do: id |> Integer.to_string(16) |> String.pad_leading(digits, "0") |> String.downcase()

  defp exported do
    receive do
      {:span, record} -> record
    after
      1_000 -> flunk("no se exportó ningún span")
    end
  end

  defp attributes(record), do: record |> span(:attributes) |> :otel_attributes.map()

  defp conn(method, path, headers \\ []) do
    Enum.reduce(headers, Plug.Test.conn(method, path), fn {key, value}, acc ->
      Plug.Conn.put_req_header(acc, key, value)
    end)
  end

  defp request(conn, status) do
    :telemetry.execute([:phoenix, :endpoint, :start], %{}, %{conn: conn})

    :telemetry.execute([:phoenix, :endpoint, :stop], %{duration: 1_000}, %{
      conn: %{conn | status: status}
    })
  end

  describe "http spans" do
    test "are named after the route pattern and carry only method, route and status" do
      request(conn(:delete, "/v1/blocks/#{@uuid}?ticket=SECRET-TICKET&x=1"), 204)

      record = exported()

      assert span(record, :name) == "DELETE /v1/blocks/:user_id"
      assert span(record, :kind) == :server

      assert attributes(record) == %{
               "http.request.method" => "DELETE",
               "http.route" => "/v1/blocks/:user_id",
               "http.response.status_code" => 204
             }

      refute inspect(record) =~ @uuid
      refute inspect(record) =~ "SECRET-TICKET"
    end

    test "an unknown route is recorded as unmatched, without its path" do
      request(conn(:get, "/no/existe/#{@uuid}"), 404)

      record = exported()

      assert span(record, :name) == "GET unmatched"
      refute inspect(record) =~ @uuid
    end

    test "continue the trace that arrives in the traceparent header" do
      request(conn(:get, "/v1/blocks", [{"traceparent", @traceparent}]), 200)

      record = exported()

      assert hex(span(record, :trace_id), 32) == @trace_id
      assert hex(span(record, :parent_span_id), 16) == @parent_span_id
    end

    test "a server error marks the span as an error" do
      request(conn(:get, "/v1/blocks"), 500)

      assert {:status, :error, _message} = span(exported(), :status)
    end

    test "a client error does not" do
      request(conn(:get, "/v1/blocks"), 404)

      refute match?({:status, :error, _}, span(exported(), :status))
    end

    test "the http_request log line carries the trace and span ids" do
      log =
        capture_log([level: :debug], fn ->
          request(conn(:get, "/v1/blocks", [{"traceparent", @traceparent}]), 200)
        end)

      record = exported()

      line =
        log
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)
        |> Enum.find(&(&1["message"] == "http_request"))

      assert line["trace_id"] == @trace_id
      assert line["span_id"] == hex(span(record, :span_id), 16)
    end

    test "a stop without a start is ignored" do
      assert :ok =
               Messaging.Tracing.handle_event(
                 [:phoenix, :endpoint, :stop],
                 %{},
                 %{conn: %{conn(:get, "/v1/blocks") | status: 200}},
                 nil
               )

      refute_receive {:span, _}, 100
    end
  end

  describe "consumer_span/3" do
    defp meta(headers),
      do: %{routing_key: "servers.member_joined", headers: headers}

    test "follows the trace that came in the traceparent header of the message" do
      result =
        Messaging.Tracing.consumer_span(
          meta([{"traceparent", :longstr, @traceparent}]),
          "messaging.channel_lifecycle",
          fn -> :processed end
        )

      assert result == :processed

      record = exported()
      assert span(record, :name) == "servers.member_joined process"
      assert span(record, :kind) == :consumer
      assert hex(span(record, :trace_id), 32) == @trace_id
      assert hex(span(record, :parent_span_id), 16) == @parent_span_id

      assert attributes(record) == %{
               "messaging.system" => "rabbitmq",
               "messaging.destination.name" => "messaging.channel_lifecycle",
               "messaging.rabbitmq.destination.routing_key" => "servers.member_joined"
             }
    end

    test "starts a new trace when the message carries none" do
      for headers <- [:undefined, [], [{"x-other", :longstr, "value"}]] do
        assert :ok = Messaging.Tracing.consumer_span(meta(headers), "q", fn -> :ok end)

        record = exported()
        assert span(record, :parent_span_id) == :undefined
        assert span(record, :trace_id) != 0
      end
    end

    test "the log lines written while processing carry the ids, and they are cleared afterwards" do
      log =
        capture_log([level: :debug], fn ->
          Messaging.Tracing.consumer_span(
            meta([{"traceparent", :longstr, @traceparent}]),
            "q",
            fn ->
              require Logger
              Logger.info("inside")
            end
          )
        end)

      assert %{"trace_id" => @trace_id, "span_id" => span_id} = Jason.decode!(String.trim(log))
      assert span_id == hex(span(exported(), :span_id), 16)

      refute Keyword.has_key?(Logger.metadata(), :trace_id)
    end

    test "an outcome that asks for a retry marks the span as an error, any other does not" do
      Messaging.Tracing.consumer_span(meta(:undefined), "q", fn ->
        Messaging.Tracing.mark_outcome(:retry)
      end)

      assert {:status, :error, _message} = span(exported(), :status)

      Messaging.Tracing.consumer_span(meta(:undefined), "q", fn ->
        Messaging.Tracing.mark_outcome(:ack)
      end)

      refute match?({:status, :error, _}, span(exported(), :status))
    end

    test "the metadata is cleared and the context detached even if processing raises" do
      assert_raise RuntimeError, "boom", fn ->
        Messaging.Tracing.consumer_span(meta(:undefined), "q", fn -> raise "boom" end)
      end

      refute Keyword.has_key?(Logger.metadata(), :trace_id)
      assert OpenTelemetry.Tracer.current_span_ctx() == :undefined
    end
  end
end
