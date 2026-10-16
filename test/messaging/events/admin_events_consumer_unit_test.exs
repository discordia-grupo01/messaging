defmodule Messaging.Events.AdminEventsConsumerUnitTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Mox

  alias Messaging.Events.AdminEventsConsumer
  alias Messaging.Suspension.Signature

  @unreachable_url "amqp://guest:guest@127.0.0.1:1/"
  @queue "messaging.admin_events"
  @secret "shared-secret"

  setup :set_mox_from_context
  setup :verify_on_exit!

  test "does not start without the HMAC secret and says so" do
    log =
      capture_log([level: :error], fn ->
        assert :ignore = AdminEventsConsumer.init(url: @unreachable_url, secret: nil)
        assert :ignore = AdminEventsConsumer.init(url: @unreachable_url, secret: "")
      end)

    assert log =~ "admin_events_consumer_not_started"
  end

  test "init/1 starts disconnected and schedules a connect attempt" do
    assert {:ok,
            %{url: @unreachable_url, queue: @queue, secret: @secret, conn: nil, chan: nil} =
              state} = AdminEventsConsumer.init(url: @unreachable_url, secret: @secret)

    assert_received :connect
    assert state.backoff > 0
  end

  test "handle_info(:connect, ...) backs off and stays disconnected when the broker is unreachable" do
    state = state(backoff: 50)

    assert {:noreply, %{conn: nil, chan: nil, backoff: 100}} =
             AdminEventsConsumer.handle_info(:connect, state)

    assert_receive :connect, 500
  end

  test "handle_info({:DOWN, ...}) resets state and retries" do
    state = state(backoff: 30_000, conn: :fake_conn, chan: :fake_chan)

    assert {:noreply, %{conn: nil, chan: nil, backoff: backoff}} =
             AdminEventsConsumer.handle_info(
               {:DOWN, make_ref(), :process, self(), :shutdown},
               state
             )

    assert backoff < 30_000
    assert_received :connect
  end

  test "consume and cancel acknowledgements are handled" do
    state = state()

    assert {:noreply, ^state} = AdminEventsConsumer.handle_info({:basic_consume_ok, %{}}, state)
    assert {:noreply, ^state} = AdminEventsConsumer.handle_info({:basic_cancel_ok, %{}}, state)
    assert {:stop, :normal, ^state} = AdminEventsConsumer.handle_info({:basic_cancel, %{}}, state)
  end

  test "a failure in Mongo asks for the delivery to be requeued" do
    user = Messaging.UUID.generate()

    expect(Messaging.Chat.RepoMock, :apply_suspension, fn ^user, true, 3 ->
      {:error, :not_connected}
    end)

    log =
      capture_log([level: :error], fn ->
        assert :retry =
                 AdminEventsConsumer.process(
                   signed("admin.user_suspended", user, 3),
                   "admin.user_suspended",
                   @secret
                 )
      end)

    assert log =~ "admin_events_consumer_event_failed"
  end

  test "terminate/2 without a connection does nothing" do
    assert :ok = AdminEventsConsumer.terminate(:normal, state())
  end

  test "binds exactly the two admin routing keys" do
    assert AdminEventsConsumer.routing_keys() == [
             "admin.user_suspended",
             "admin.user_reactivated"
           ]
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

  defp signed(routing_key, user_id, version) do
    event = %{
      routing_key: routing_key,
      event_id: Messaging.UUID.generate(),
      user_id: user_id,
      version: version,
      occurred_at: "2026-10-15T12:00:00.5Z"
    }

    Jason.encode!(%{
      "event_id" => event.event_id,
      "occurred_at" => event.occurred_at,
      "user_id" => user_id,
      "version" => version,
      "signature" => Signature.sign(event, @secret)
    })
  end
end
