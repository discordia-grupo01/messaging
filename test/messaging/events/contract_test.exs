defmodule Messaging.Events.ContractTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Messaging.Events.Contract

  @examples Path.join(Mix.Project.deps_paths().events_contract, "examples")

  setup do
    previous = Application.get_env(:messaging, :event_contract_check)
    Application.put_env(:messaging, :event_contract_check, :warn)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:messaging, :event_contract_check, previous),
        else: Application.delete_env(:messaging, :event_contract_check)
    end)
  end

  defp example(key), do: @examples |> Path.join(key <> ".json") |> File.read!() |> Jason.decode!()

  test "accepts every example of the contract without logging anything" do
    keys = @examples |> File.ls!() |> Enum.map(&Path.basename(&1, ".json"))
    assert keys != []

    log =
      capture_log(fn ->
        for key <- keys, do: assert(Contract.check(key, example(key)) == :ok)
      end)

    refute log =~ "event_contract_violation"
  end

  test "reports a violation without leaking the received values" do
    event =
      example("messaging.message_created")
      |> Map.put("content_preview", String.duplicate("secreto", 40))

    log =
      capture_log(fn ->
        assert {:error, [_ | _]} = Contract.check("messaging.message_created", event)
      end)

    assert log =~ "event_contract_violation"
    assert log =~ "messaging.message_created"
    refute log =~ "secreto"
  end

  test "accepts a body that is already encoded" do
    body = "servers.member_left" |> example() |> Jason.encode!()
    assert Contract.check("servers.member_left", body) == :ok
  end

  test "ignores events the contract does not know" do
    assert Contract.check("otro.evento", %{"x" => 1}) == :ok
  end

  test "does nothing when the check is turned off" do
    Application.put_env(:messaging, :event_contract_check, :off)

    log = capture_log(fn -> assert Contract.check("servers.member_left", %{}) == :ok end)

    refute log =~ "event_contract_violation"
  end
end
