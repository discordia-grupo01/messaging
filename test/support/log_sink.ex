defmodule Messaging.LogSink do
  @behaviour Plug

  import Plug.Conn

  @agent Messaging.LogSink.State

  def start(owner, statuses \\ []) do
    ref = :"log_sink_#{System.unique_integer([:positive])}"
    {:ok, _agent} = Agent.start_link(fn -> %{owner: owner, statuses: statuses} end, name: @agent)
    {:ok, _pid} = Plug.Cowboy.http(__MODULE__, [], port: 0, ref: ref)
    url = "http://127.0.0.1:#{:ranch.get_port(ref)}/log/v1"
    {:ok, url, fn -> stop(ref) end}
  end

  defp stop(ref) do
    Plug.Cowboy.shutdown(ref)
    if Process.whereis(@agent), do: Agent.stop(@agent)
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(options), do: options

  @impl true
  def call(conn, _options) do
    {:ok, raw, conn} = read_body(conn)

    body =
      case get_req_header(conn, "content-encoding") do
        ["gzip"] -> :zlib.gunzip(raw)
        _other -> raw
      end

    %{owner: owner} = Agent.get(@agent, & &1)

    send(owner, {:sink, %{headers: Map.new(conn.req_headers), body: Jason.decode!(body)}})

    send_resp(conn, next_status(), "{}")
  end

  defp next_status do
    Agent.get_and_update(@agent, fn
      %{statuses: [status | rest]} = state -> {status, %{state | statuses: rest}}
      state -> {202, state}
    end)
  end
end
