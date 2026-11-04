defmodule Messaging.Events.BillingEventsConsumerUnitTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Mox

  alias Messaging.Events.BillingEventsConsumer
  alias Messaging.Premium.Signature

  @unreachable_url "amqp://guest:guest@127.0.0.1:1/"
  @queue "messaging.billing_events"
  @routing_key "billing.premium_updated"
  @secret "shared-secret"

  setup :set_mox_from_context
  setup :verify_on_exit!

  test "does not start without the HMAC secret and says so" do
    log =
      capture_log([level: :error], fn ->
        assert :ignore = BillingEventsConsumer.init(url: @unreachable_url, secret: nil)
        assert :ignore = BillingEventsConsumer.init(url: @unreachable_url, secret: "")
      end)

    assert log =~ "billing_events_consumer_not_started"
  end

  test "init/1 starts disconnected and schedules a connect attempt" do
    assert {:ok,
            %{url: @unreachable_url, queue: @queue, secret: @secret, conn: nil, chan: nil} =
              state} = BillingEventsConsumer.init(url: @unreachable_url, secret: @secret)

    assert_received :connect
    assert state.backoff > 0
  end

  test "handle_info(:connect, ...) backs off and stays disconnected when the broker is unreachable" do
    state = state(backoff: 50)

    assert {:noreply, %{conn: nil, chan: nil, backoff: 100}} =
             BillingEventsConsumer.handle_info(:connect, state)

    assert_receive :connect, 500
  end

  test "handle_info({:DOWN, ...}) resets state and retries" do
    state = state(backoff: 30_000, conn: :fake_conn, chan: :fake_chan)

    assert {:noreply, %{conn: nil, chan: nil, backoff: backoff}} =
             BillingEventsConsumer.handle_info(
               {:DOWN, make_ref(), :process, self(), :shutdown},
               state
             )

    assert backoff < 30_000
    assert_received :connect
  end

  test "consume and cancel acknowledgements are handled" do
    state = state()

    assert {:noreply, ^state} = BillingEventsConsumer.handle_info({:basic_consume_ok, %{}}, state)
    assert {:noreply, ^state} = BillingEventsConsumer.handle_info({:basic_cancel_ok, %{}}, state)

    assert {:stop, :normal, ^state} =
             BillingEventsConsumer.handle_info({:basic_cancel, %{}}, state)
  end

  test "terminate/2 without a connection does nothing" do
    assert :ok = BillingEventsConsumer.terminate(:normal, state())
  end

  test "binds the premium routing key" do
    assert BillingEventsConsumer.routing_key() == @routing_key
  end

  describe "process/3" do
    setup do
      {:ok, user: Messaging.UUID.generate()}
    end

    test "applies a signed event", %{user: user} do
      expect(Messaging.Chat.RepoMock, :apply_premium, fn ^user, true, 3 -> {:ok, :applied} end)

      assert :ack = BillingEventsConsumer.process(signed(user, true, 3), @routing_key, @secret)
    end

    test "a stale event is acknowledged", %{user: user} do
      expect(Messaging.Chat.RepoMock, :apply_premium, fn ^user, false, 1 -> {:ok, :stale} end)

      assert :ack = BillingEventsConsumer.process(signed(user, false, 1), @routing_key, @secret)
    end

    test "a failure in Mongo asks for the delivery to be requeued", %{user: user} do
      expect(Messaging.Chat.RepoMock, :apply_premium, fn ^user, true, 3 ->
        {:error, :not_connected}
      end)

      log =
        capture_log([level: :error], fn ->
          assert :retry =
                   BillingEventsConsumer.process(signed(user, true, 3), @routing_key, @secret)
        end)

      assert log =~ "billing_events_consumer_event_failed"
    end

    test "an event signed with another secret changes nothing", %{user: user} do
      log =
        capture_log([level: :warning], fn ->
          assert :ack =
                   BillingEventsConsumer.process(signed(user, true, 3), @routing_key, "other")
        end)

      assert log =~ "billing_events_consumer_invalid_signature"
    end

    test "a tampered event changes nothing", %{user: user} do
      tampered =
        signed(user, false, 3)
        |> Jason.decode!()
        |> Map.put("active", true)
        |> Jason.encode!()

      capture_log([level: :warning], fn ->
        assert :ack = BillingEventsConsumer.process(tampered, @routing_key, @secret)
      end)
    end

    test "an unknown routing key changes nothing", %{user: user} do
      log =
        capture_log([level: :warning], fn ->
          assert :ack =
                   BillingEventsConsumer.process(signed(user, true, 3), "billing.other", @secret)
        end)

      assert log =~ "unknown_routing_key"
    end

    test "a payload with missing or wrong fields changes nothing", %{user: user} do
      for payload <- [
            %{"user_id" => user},
            %{"user_id" => user, "version" => "3", "active" => true},
            Map.put(Jason.decode!(signed(user, true, 3)), "active", "true"),
            Map.put(Jason.decode!(signed(user, true, 3)), "user_id", "")
          ] do
        log =
          capture_log([level: :warning], fn ->
            assert :ack =
                     BillingEventsConsumer.process(
                       Jason.encode!(payload),
                       @routing_key,
                       @secret
                     )
          end)

        assert log =~ "billing_events_consumer_bad_message"
      end
    end

    test "something that is not a JSON object changes nothing" do
      for payload <- ["not json", "[1, 2]"] do
        log =
          capture_log([level: :warning], fn ->
            assert :ack = BillingEventsConsumer.process(payload, @routing_key, @secret)
          end)

        assert log =~ "billing_events_consumer_bad_message"
      end
    end
  end

  defp state(overrides \\ []) do
    Map.merge(
      %{
        url: @unreachable_url,
        queue: @queue,
        secret: @secret,
        backoff: 1_000,
        conn: nil,
        chan: nil
      },
      Map.new(overrides)
    )
  end

  defp signed(user_id, active, version) do
    event = %{
      "event_id" => Messaging.UUID.generate(),
      "occurred_at" => "2026-11-03T12:30:45.5Z",
      "user_id" => user_id,
      "active" => active,
      "premium_until" => if(active, do: "2026-12-03T12:30:45Z"),
      "renews" => active,
      "version" => version
    }

    event |> Map.put("signature", Signature.sign(event, @secret)) |> Jason.encode!()
  end
end
