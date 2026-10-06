defmodule Messaging.Log.TelemetryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  setup do
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)
  end

  @uuid "22222222-2222-4222-8222-222222222222"

  defp conn(method, path, status, assigns \\ %{}) do
    Plug.Test.conn(method, path)
    |> Map.put(:status, status)
    |> Map.update!(:assigns, &Map.merge(&1, assigns))
  end

  defp entries(fun) do
    [level: :debug]
    |> capture_log(fun)
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp stop(conn, duration_ms \\ 12) do
    :telemetry.execute(
      [:phoenix, :endpoint, :stop],
      %{duration: System.convert_time_unit(duration_ms, :millisecond, :native)},
      %{conn: conn}
    )
  end

  describe "http_request" do
    test "logs structured fields: method, route, status, duration and who made the call" do
      [entry] =
        entries(fn ->
          stop(conn(:post, "/v1/blocks", 204, %{user_id: "u-1"}), 12)
        end)

      assert %{
               "message" => "http_request",
               "level" => "info",
               "method" => "POST",
               "route" => "/v1/blocks",
               "status" => 204,
               "duration_ms" => 12.0,
               "user_id" => "u-1"
             } = entry
    end

    test "writes the route pattern, never the real path, so ids and the query string stay out" do
      [entry] =
        entries(fn ->
          stop(conn(:delete, "/v1/blocks/#{@uuid}?ticket=SECRET-TICKET&x=1", 204))
        end)

      assert entry["route"] == "/v1/blocks/:user_id"
      refute inspect(entry) =~ @uuid
      refute inspect(entry) =~ "SECRET-TICKET"
    end

    test "a request that matched no route is logged as unmatched, without its path" do
      [entry] = entries(fn -> stop(conn(:get, "/v1/blocks/#{@uuid}/nope", 404)) end)

      assert %{"route" => "unmatched", "status" => 404} = entry
      refute inspect(entry) =~ @uuid
    end

    test "the level follows the status: 5xx is an error, the rest is info" do
      for {status, level} <- [
            {200, "info"},
            {401, "info"},
            {404, "info"},
            {500, "error"},
            {503, "error"}
          ] do
        [entry] = entries(fn -> stop(conn(:get, "/v1/blocks", status)) end)
        assert entry["level"] == level
      end
    end

    test "health checks are debug, so they do not flood the info level" do
      for route <- ["/livez", "/readyz"] do
        [entry] = entries(fn -> stop(conn(:get, route, 200)) end)
        assert entry["level"] == "debug"
        assert entry["route"] == route
      end
    end

    test "nothing is written for health checks when the level is info" do
      Logger.configure(level: :info)

      assert capture_log(fn -> stop(conn(:get, "/livez", 200)) end) == ""
    end

    test "an unauthenticated request has no user_id" do
      [entry] = entries(fn -> stop(conn(:get, "/v1/blocks", 401)) end)

      assert entry["user_id"] == nil
    end
  end

  describe "http_error_rendered" do
    test "is an error with the sanitized reason, not the exception payload" do
      [entry] =
        entries(fn ->
          :telemetry.execute([:phoenix, :error_rendered], %{}, %{
            conn: conn(:get, "/v1/blocks", 500),
            status: 500,
            kind: :error,
            reason: %Jason.DecodeError{data: "private text", position: 0}
          })
        end)

      assert %{"message" => "http_error_rendered", "level" => "error", "status" => 500} = entry
      assert entry["reason"] =~ "Jason.DecodeError"
      refute inspect(entry) =~ "private text"
    end
  end

  describe "sockets and channels" do
    defp socket(topic, assigns), do: %Phoenix.Socket{topic: topic, assigns: assigns}

    test "socket_connected carries only the result and the transport, never the ticket" do
      [entry] =
        entries(fn ->
          :telemetry.execute([:phoenix, :socket_connected], %{duration: 1_000}, %{
            result: :ok,
            transport: :websocket,
            params: %{"ticket" => "SECRET-TICKET"}
          })
        end)

      assert %{
               "message" => "socket_connected",
               "level" => "info",
               "result" => "ok",
               "transport" => "websocket"
             } =
               entry

      refute inspect(entry) =~ "SECRET-TICKET"
    end

    test "a failed socket connection is a warning" do
      [entry] =
        entries(fn ->
          :telemetry.execute([:phoenix, :socket_connected], %{duration: 1_000}, %{
            result: :error,
            transport: :websocket,
            params: %{}
          })
        end)

      assert %{"level" => "warning", "result" => "error"} = entry
    end

    test "channel_joined tells who joined what and whether it was refused" do
      for result <- [:ok, :error] do
        [entry] =
          entries(fn ->
            :telemetry.execute([:phoenix, :channel_joined], %{duration: 1_000}, %{
              result: result,
              socket: socket("channel:c-1", %{user_id: "u-1"}),
              params: %{"last_message_id" => "x"}
            })
          end)

        assert %{
                 "message" => "channel_joined",
                 "level" => "info",
                 "topic" => "channel:c-1",
                 "user_id" => "u-1"
               } = entry

        assert entry["result"] == Atom.to_string(result)
      end
    end

    test "channel_event is debug, names the event and never the payload" do
      [entry] =
        entries(fn ->
          :telemetry.execute([:phoenix, :channel_handled_in], %{duration: 1_000}, %{
            event: "send_dm",
            socket: socket("user:u-1", %{user_id: "u-1"}),
            params: %{"content" => "SECRET-TEXT", "to" => "SECRET-TO"}
          })
        end)

      assert %{"message" => "channel_event", "level" => "debug", "event" => "send_dm"} = entry
      refute inspect(entry) =~ "SECRET"
    end
  end

  test "attach/0 can be called twice without failing or duplicating the log lines" do
    assert :ok = Messaging.Log.Telemetry.attach()
    assert :ok = Messaging.Log.Telemetry.attach()

    assert [_one] = entries(fn -> stop(conn(:get, "/v1/blocks", 200)) end)
  end
end
