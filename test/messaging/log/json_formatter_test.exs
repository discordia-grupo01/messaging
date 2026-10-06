defmodule Messaging.Log.JSONFormatterTest do
  use ExUnit.Case, async: true

  alias Messaging.Log.JSONFormatter

  defp decode(iodata),
    do: iodata |> IO.iodata_to_binary() |> String.trim_trailing() |> Jason.decode!()

  test "every entry is one line of valid JSON with the standard fields" do
    line = IO.iodata_to_binary(JSONFormatter.format(:info, "message_sent", nil, []))

    assert String.ends_with?(line, "\n")
    assert length(String.split(String.trim_trailing(line), "\n")) == 1

    assert %{
             "level" => "info",
             "service" => "messaging",
             "message" => "message_sent",
             "time" => time
           } =
             Jason.decode!(line)

    assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(time)
  end

  test "keeps the level exactly as given, for the four levels" do
    for level <- [:debug, :info, :warning, :error] do
      assert %{"level" => name} = decode(JSONFormatter.format(level, "x", nil, []))
      assert name == Atom.to_string(level)
    end
  end

  test "metadata becomes top-level fields, with proper types" do
    entry =
      decode(
        JSONFormatter.format(:info, "x", nil,
          channel_id: "c-1",
          attempts: 3,
          allowed: true,
          reason: :timeout,
          nothing: nil
        )
      )

    assert %{
             "channel_id" => "c-1",
             "attempts" => 3,
             "allowed" => true,
             "reason" => "timeout",
             "nothing" => nil
           } =
             entry
  end

  test "Logger internals are left out" do
    entry =
      decode(
        JSONFormatter.format(:info, "x", nil,
          pid: self(),
          mfa: {Mod, :fun, 1},
          file: "a.ex",
          line: 3,
          user_id: "u-1"
        )
      )

    assert entry["user_id"] == "u-1"

    for key <- ["pid", "mfa", "file", "line"], do: refute(Map.has_key?(entry, key))
  end

  test "sensitive keys are never written, even if someone adds them to the metadata" do
    entry =
      decode(
        JSONFormatter.format(:info, "x", nil,
          content: "secret message",
          to: "someone",
          ticket: "abc",
          token: "t",
          raw_jwt: "a.b.c",
          authorization: "Bearer x",
          password: "p"
        )
      )

    for key <- ~w(content to ticket token raw_jwt authorization password) do
      assert entry[key] == "[FILTERED]"
    end

    refute inspect(entry) =~ "secret message"
    refute inspect(entry) =~ "a.b.c"
  end

  test "values that are not JSON friendly do not break the line" do
    entry =
      decode(
        JSONFormatter.format(:warning, "x", nil, reason: {:error, self()}, status: make_ref())
      )

    assert is_binary(entry["reason"]) and is_binary(entry["status"])
  end

  test "accepts messages that are chardata, as the framework logs them" do
    entry = decode(JSONFormatter.format(:info, ["GET ", ["/v1/blocks"]], nil, []))
    assert entry["message"] == "GET /v1/blocks"
  end

  test "a message with newlines stays on one physical line" do
    line = IO.iodata_to_binary(JSONFormatter.format(:debug, "a\nb\nParameters: %{}", nil, []))

    assert length(String.split(String.trim_trailing(line), "\n")) == 1
    assert Jason.decode!(line)["message"] == "a\nb\nParameters: %{}"
  end

  test "very long messages are truncated" do
    entry = decode(JSONFormatter.format(:info, String.duplicate("a", 10_000), nil, []))
    assert String.length(entry["message"]) == 2_000
  end

  test "invalid UTF-8 is written as text instead of crashing" do
    entry = decode(JSONFormatter.format(:info, "x", nil, reason: <<255, 254>>))
    assert is_binary(entry["reason"])
  end

  test "a formatter failure still yields a valid line" do
    line = IO.iodata_to_binary(JSONFormatter.format(:info, "x", nil, :not_a_keyword))
    assert %{"level" => "error", "message" => "log_format_failed"} = Jason.decode!(line)
  end
end
