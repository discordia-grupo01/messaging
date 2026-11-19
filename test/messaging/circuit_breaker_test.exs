defmodule Messaging.CircuitBreakerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Messaging.CircuitBreaker

  setup do
    name = {:test, System.unique_integer([:positive])}
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> CircuitBreaker.reset(name) end)

    options = [threshold: 3, open_ms: 30_000, now_ms: fn -> Agent.get(clock, & &1) end]
    advance = fn ms -> Agent.update(clock, &(&1 + ms)) end
    {:ok, name: name, options: options, advance: advance}
  end

  defp fail(name, options), do: CircuitBreaker.call(name, fn -> {:error, :boom} end, options)

  defp succeed(name, options),
    do: CircuitBreaker.call(name, fn -> {:ok, %{status: 200}} end, options)

  test "a new breaker is closed and lets calls through", %{name: name, options: options} do
    assert CircuitBreaker.state(name, options) == :closed
    assert succeed(name, options) == {:ok, %{status: 200}}
  end

  test "opens after the configured number of consecutive failures", %{
    name: name,
    options: options
  } do
    capture_log(fn ->
      assert fail(name, options) == {:error, :boom}
      assert fail(name, options) == {:error, :boom}
      assert CircuitBreaker.state(name, options) == :closed
      assert fail(name, options) == {:error, :boom}
      assert CircuitBreaker.state(name, options) == :open
    end)
  end

  test "a success in between resets the count", %{name: name, options: options} do
    fail(name, options)
    fail(name, options)
    succeed(name, options)
    fail(name, options)
    fail(name, options)

    assert CircuitBreaker.state(name, options) == :closed
  end

  test "an open breaker answers :circuit_open without running the call", %{
    name: name,
    options: options
  } do
    capture_log(fn -> for _ <- 1..3, do: fail(name, options) end)
    test_pid = self()

    result = CircuitBreaker.call(name, fn -> send(test_pid, :ran) end, options)

    assert result == {:error, :circuit_open}
    refute_received :ran
  end

  test "after the open time one probe is let through and a success closes it", %{
    name: name,
    options: options,
    advance: advance
  } do
    capture_log(fn ->
      for _ <- 1..3, do: fail(name, options)
      advance.(29_000)
      assert succeed(name, options) == {:error, :circuit_open}

      advance.(2_000)
      assert CircuitBreaker.state(name, options) == :half_open
      assert succeed(name, options) == {:ok, %{status: 200}}
      assert CircuitBreaker.state(name, options) == :closed
    end)
  end

  test "a failed probe reopens it for another full open time", %{
    name: name,
    options: options,
    advance: advance
  } do
    capture_log(fn ->
      for _ <- 1..3, do: fail(name, options)
      advance.(31_000)
      assert fail(name, options) == {:error, :boom}
      assert CircuitBreaker.state(name, options) == :open

      advance.(29_000)
      assert succeed(name, options) == {:error, :circuit_open}
    end)
  end

  test "only one probe goes through while it is half open", %{
    name: name,
    options: options,
    advance: advance
  } do
    capture_log(fn ->
      for _ <- 1..3, do: fail(name, options)
      advance.(31_000)
      test_pid = self()

      CircuitBreaker.call(
        name,
        fn ->
          send(test_pid, {:inner, CircuitBreaker.call(name, fn -> :second end, options)})
          {:ok, %{status: 200}}
        end,
        options
      )

      assert_received {:inner, {:error, :circuit_open}}
      assert CircuitBreaker.state(name, options) == :closed
    end)
  end

  test "a probe that never reports back expires and another one is allowed", %{
    name: name,
    options: options,
    advance: advance
  } do
    capture_log(fn ->
      for _ <- 1..3, do: fail(name, options)
      advance.(31_000)

      pid =
        spawn(fn -> CircuitBreaker.call(name, fn -> Process.sleep(:infinity) end, options) end)

      Process.sleep(50)
      assert succeed(name, options) == {:error, :circuit_open}

      advance.(31_000)
      assert succeed(name, options) == {:ok, %{status: 200}}
      Process.exit(pid, :kill)
    end)
  end

  test "server errors and rate limits count but client errors do not", %{
    name: name,
    options: options
  } do
    for status <- [400, 401, 404, 409] do
      for _ <- 1..4, do: CircuitBreaker.call(name, fn -> {:ok, %{status: status}} end, options)
    end

    assert CircuitBreaker.state(name, options) == :closed

    capture_log(fn ->
      for status <- [500, 502, 429] do
        CircuitBreaker.call(name, fn -> {:ok, %{status: status}} end, options)
      end
    end)

    assert CircuitBreaker.state(name, options) == :open
  end

  test "a custom failure predicate decides what counts", %{name: name, options: options} do
    options = Keyword.put(options, :failure?, &match?({:error, :down}, &1))

    for _ <- 1..5, do: CircuitBreaker.call(name, fn -> {:error, :other} end, options)
    assert CircuitBreaker.state(name, options) == :closed

    capture_log(fn ->
      for _ <- 1..3, do: CircuitBreaker.call(name, fn -> {:error, :down} end, options)
    end)

    assert CircuitBreaker.state(name, options) == :open
  end

  test "an exception counts as a failure and is raised again", %{name: name, options: options} do
    capture_log(fn ->
      for _ <- 1..3 do
        assert_raise RuntimeError, "boom", fn ->
          CircuitBreaker.call(name, fn -> raise "boom" end, options)
        end
      end
    end)

    assert CircuitBreaker.state(name, options) == :open
  end

  test "each name has its own state", %{name: name, options: options} do
    other = {:other, name}
    on_exit(fn -> CircuitBreaker.reset(other) end)

    capture_log(fn -> for _ <- 1..3, do: fail(name, options) end)

    assert CircuitBreaker.state(name, options) == :open
    assert CircuitBreaker.state(other, options) == :closed
  end

  test "logs the changes of state", %{name: name, options: options} do
    log = capture_log(fn -> for _ <- 1..3, do: fail(name, options) end)

    assert log =~ "circuit_breaker_state_changed"
  end

  test "concurrent use does not break it", %{name: name} do
    options = [threshold: 3, open_ms: 1]

    capture_log(fn ->
      1..50
      |> Enum.map(fn i ->
        Task.async(fn ->
          for j <- 1..50 do
            CircuitBreaker.call(
              name,
              fn -> if rem(i + j, 3) == 0, do: {:error, :boom}, else: :ok end,
              options
            )
          end
        end)
      end)
      |> Task.await_many(10_000)
    end)

    assert CircuitBreaker.state(name, options) in [:closed, :open, :half_open]
  end

  test "reset forgets everything", %{name: name, options: options} do
    capture_log(fn -> for _ <- 1..3, do: fail(name, options) end)

    assert CircuitBreaker.reset(name) == :ok
    assert CircuitBreaker.state(name, options) == :closed
  end
end
