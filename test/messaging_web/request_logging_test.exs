defmodule MessagingWeb.RequestLoggingTest do
  use MessagingWeb.ConnCase, async: false
  import ExUnit.CaptureLog
  import Mox

  alias Messaging.AuthFixtures

  setup :verify_on_exit!

  setup do
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)
  end

  @me "11111111-1111-4111-8111-111111111111"
  @other "22222222-2222-4222-8222-222222222222"

  defp authed(conn),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> AuthFixtures.token_for(@me))

  defp entries(log), do: log |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

  test "a real request is logged with its route pattern, not with the ids in the path", %{
    conn: conn
  } do
    expect(Messaging.Chat.RepoMock, :delete_block, fn _id -> :ok end)

    log =
      capture_log([level: :debug], fn -> conn |> authed() |> delete("/v1/blocks/#{@other}") end)

    assert %{
             "route" => "/v1/blocks/:user_id",
             "method" => "DELETE",
             "status" => 204,
             "user_id" => @me
           } =
             Enum.find(entries(log), &(&1["message"] == "http_request"))

    refute log =~ @other
  end

  test "the query string never reaches the logs", %{conn: conn} do
    expect(Messaging.Chat.RepoMock, :list_blocks, fn _id, _limit -> {:ok, []} end)

    log =
      capture_log([level: :debug], fn ->
        conn |> authed() |> get("/v1/blocks?limit=5&ticket=SECRET-TICKET&token=SECRET-TOKEN")
      end)

    refute log =~ "SECRET"
  end

  test "the request id travels with every line of the request", %{conn: conn} do
    expect(Messaging.Chat.RepoMock, :delete_block, fn _id -> :ok end)

    log =
      capture_log([level: :debug], fn -> conn |> authed() |> delete("/v1/blocks/#{@other}") end)

    lines = entries(log)

    request_ids = for %{"request_id" => id} <- lines, uniq: true, do: id
    assert [id] = request_ids
    assert is_binary(id)
    assert Enum.any?(lines, &(&1["message"] == "block_removed"))
  end

  test "an unknown route is logged without its path", %{conn: conn} do
    log = capture_log([level: :debug], fn -> get(conn, "/no/existe/#{@other}") end)

    assert %{"route" => "unmatched", "status" => 404} =
             Enum.find(entries(log), &(&1["message"] == "http_request"))

    refute log =~ @other
  end

  test "no line is plain text: everything the request writes is JSON", %{conn: conn} do
    expect(Messaging.Chat.RepoMock, :list_blocks, fn _id, _limit -> {:ok, []} end)

    log = capture_log([level: :debug], fn -> conn |> authed() |> get("/v1/blocks") end)

    assert log != ""

    for line <- String.split(log, "\n", trim: true),
        do: assert(%{"level" => _} = Jason.decode!(line))

    refute log =~ "Processing with"
    refute log =~ "Parameters"
  end
end
