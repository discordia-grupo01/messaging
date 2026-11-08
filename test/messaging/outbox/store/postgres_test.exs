database_host = System.get_env("DATABASE_HOST")

if database_host do
  defmodule Messaging.Outbox.Store.PostgresTest do
    use ExUnit.Case, async: false

    alias Messaging.Outbox.Store.Postgres, as: Store
    alias Messaging.Postgres

    @schema "outbox_test"

    setup do
      previous_postgres = Application.get_env(:messaging, :postgres)
      previous_store = Application.get_env(:messaging, :outbox_store)

      Application.put_env(:messaging, :postgres,
        host: System.fetch_env!("DATABASE_HOST"),
        port: String.to_integer(System.get_env("DATABASE_PORT", "5432")),
        database: System.get_env("DATABASE_NAME", "postgres"),
        username: System.get_env("DATABASE_USER", "postgres"),
        password: System.get_env("DATABASE_PASSWORD", "postgres"),
        sslmode: "disable",
        schema: @schema,
        pool_size: 10
      )

      Application.put_env(:messaging, :outbox_store, Store)

      on_exit(fn ->
        restore(:postgres, previous_postgres)
        restore(:outbox_store, previous_store)
      end)

      start_supervised!(Postgres)
      reset_schema()
      :ok
    end

    defp restore(key, nil), do: Application.delete_env(:messaging, key)
    defp restore(key, value), do: Application.put_env(:messaging, key, value)

    defp reset_schema(migrations \\ Path.wildcard("migrations/*.up.sql")) do
      Postgrex.query!(Postgres, "DROP SCHEMA IF EXISTS #{@schema} CASCADE", [])
      Postgrex.query!(Postgres, "CREATE SCHEMA #{@schema}", [])
      migrations |> Enum.sort() |> Enum.each(&migrate/1)
    end

    defp migrate(path) do
      statements =
        path
        |> File.read!()
        |> String.split(";")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      {:ok, _} =
        Postgrex.transaction(Postgres, fn conn ->
          Postgrex.query!(conn, "SET LOCAL search_path TO #{@schema}", [])
          Enum.each(statements, &Postgrex.query!(conn, &1, []))
        end)
    end

    defp row(message_id, event \\ "new_message", overrides \\ %{}) do
      Map.merge(
        %{
          id: Messaging.UUID.generate_v7(),
          event: event,
          topic: "channel:chan-1",
          payload: %{"id" => message_id, "content" => "secreto"},
          apply: %{"op" => "insert_message", "doc" => %{"_id" => message_id}},
          message_id: message_id,
          channel_id: "chan-1"
        },
        overrides
      )
    end

    defp fetch(id) do
      %Postgrex.Result{
        rows: [[payload, apply, published_at, attempts, last_error, event, message_id]]
      } =
        Postgrex.query!(
          Postgres,
          """
          SELECT payload::text, apply::text, published_at, attempts, last_error, event, message_id
            FROM #{@schema}.outbox_events WHERE id = $1::text::uuid
          """,
          [id]
        )

      %{
        payload: payload,
        apply: apply,
        published_at: published_at,
        attempts: attempts,
        last_error: last_error,
        event: event,
        message_id: message_id
      }
    end

    defp count do
      %Postgrex.Result{rows: [[n]]} =
        Postgrex.query!(Postgres, "SELECT count(*) FROM #{@schema}.outbox_events", [])

      n
    end

    defp publish_all(rows), do: Enum.map(rows, &{&1.id, :ok})

    test "the traceparent is stored and comes back with the pending row" do
      traceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
      assert :ok = Store.insert([row("tp1", "new_message", %{traceparent: traceparent})])
      assert :ok = Store.insert([row("tp2")])

      test_pid = self()

      assert {:ok, 2} =
               Store.process_pending(10, fn rows ->
                 send(test_pid, {:rows, Map.new(rows, &{&1.message_id, &1.traceparent})})
                 publish_all(rows)
               end)

      assert_received {:rows, %{"tp1" => ^traceparent, "tp2" => nil}}
    end

    test "ping/0 answers when the database does" do
      assert :ok = Store.ping()
    end

    test "what is inserted comes back pending, with its payload and instructions" do
      r = row("m1")
      assert :ok = Store.insert([r])

      assert {:ok, 0} =
               Store.process_pending(10, fn [pending] ->
                 assert pending.id == r.id
                 assert pending.event == "new_message"
                 assert pending.topic == "channel:chan-1"
                 assert pending.payload == %{"id" => "m1", "content" => "secreto"}
                 assert pending.apply == %{"op" => "insert_message", "doc" => %{"_id" => "m1"}}
                 assert pending.message_id == "m1"
                 assert pending.channel_id == "chan-1"
                 assert pending.attempts == 0
                 []
               end)
    end

    test "publishing empties the content but keeps the row, for the audit trail" do
      r = row("m1")
      :ok = Store.insert([r])

      assert {:ok, 1} = Store.process_pending(10, &publish_all/1)

      stored = fetch(r.id)
      assert stored.payload == nil
      assert stored.apply == nil
      assert %DateTime{} = stored.published_at
      assert stored.attempts == 1
      assert stored.event == "new_message"
      assert stored.message_id == "m1"
      assert count() == 1
    end

    test "it counts only the rows that were published" do
      :ok = Store.insert([row("m1"), row("m2")])

      assert {:ok, 1} =
               Store.process_pending(10, fn [first, second] ->
                 [{first.id, :ok}, {second.id, {:retry, :unavailable}}]
               end)

      assert {:ok, 0} =
               Store.process_pending(10, fn [pending] ->
                 [{pending.id, {:retry, :unavailable}}]
               end)
    end

    test "the events of one message come out in order, one per poll" do
      first = row("m1", "new_message", %{apply: nil})
      second = row("m1", "message_updated", %{apply: nil})
      :ok = Store.insert([first])
      :ok = Store.insert([second])

      assert {:ok, 1} =
               Store.process_pending(10, fn [pending] ->
                 assert pending.id == first.id
                 [{pending.id, :ok}]
               end)

      assert {:ok, 1} =
               Store.process_pending(10, fn [pending] ->
                 assert pending.id == second.id
                 [{pending.id, :ok}]
               end)
    end

    test "a published event is never returned again" do
      :ok = Store.insert([row("m1")])
      {:ok, 1} = Store.process_pending(10, &publish_all/1)

      assert {:ok, 0} = Store.process_pending(10, fn [] -> [] end)
    end

    test "several rows are recorded all together or not at all" do
      good = row("m1")
      bad = row("m2", "new_message", %{event: nil})

      assert {:error, _reason} = Store.insert([good, bad])
      assert count() == 0
    end

    test "a message's creation events are enqueued once per topic" do
      dm = fn topic -> row("m1", "new_dm", %{topic: topic, apply: nil}) end
      created = [row("m1"), dm.("user:ana"), dm.("user:beto")]

      assert :ok = Store.insert(created)
      assert :duplicate = Store.insert([row("m1"), dm.("user:ana"), dm.("user:beto")])
      assert count() == 3
    end

    test "a batch with an already enqueued creation event inserts nothing" do
      :ok = Store.insert([row("m1")])

      assert :duplicate = Store.insert([row("m2"), row("m1")])
      assert count() == 1
    end

    test "the creation event of a published message is still not enqueued again" do
      :ok = Store.insert([row("m1")])
      {:ok, 1} = Store.process_pending(10, &publish_all/1)

      assert :duplicate = Store.insert([row("m1")])
    end

    test "other events of the same message can repeat" do
      updated = fn -> row("m1", "message_updated", %{apply: nil}) end

      assert :ok = Store.insert([updated.()])
      assert :ok = Store.insert([updated.()])
      assert count() == 2
    end

    test "two inserts of the same creation event at once: one wins, the other is a duplicate" do
      results =
        1..2
        |> Enum.map(fn _ -> Task.async(fn -> Store.insert([row("m1")]) end) end)
        |> Enum.map(&Task.await/1)

      assert Enum.sort(results) == [:duplicate, :ok]
      assert count() == 1
    end

    test "adding the creation index keeps only the first of the creation events already repeated" do
      reset_schema([
        "migrations/0001_outbox_events.up.sql",
        "migrations/0003_outbox_events_traceparent.up.sql"
      ])

      first = row("m1")
      repeated = row("m1")
      updates = for _ <- 1..2, do: row("m1", "message_updated", %{apply: nil})
      Enum.each([first, repeated | updates], &Store.insert([&1]))

      migrate("migrations/0002_outbox_events_created_once.up.sql")

      assert count() == 3
      assert %{event: "new_message"} = fetch(first.id)
      assert :duplicate = Store.insert([row("m1")])
    end

    test "events come out in the order they were recorded" do
      rows = for n <- 1..5, do: row("m#{n}")
      Enum.each(rows, &Store.insert([&1]))

      {:ok, 5} =
        Store.process_pending(10, fn pending ->
          assert Enum.map(pending, & &1.id) == Enum.map(rows, & &1.id)
          publish_all(pending)
        end)
    end

    test "the batch size is respected" do
      Store.insert(for n <- 1..5, do: row("m#{n}"))

      assert {:ok, 2} = Store.process_pending(2, &publish_all/1)
      assert {:ok, 3} = Store.process_pending(10, &publish_all/1)
    end

    test "two events of the same message never come out together: the second waits for the first" do
      first = row("m1", "new_message")
      second = row("m1", "message_updated", %{apply: nil})
      other = row("m2")
      Enum.each([first, second, other], &Store.insert([&1]))

      {:ok, 2} =
        Store.process_pending(10, fn pending ->
          assert Enum.map(pending, & &1.id) == [first.id, other.id]
          publish_all(pending)
        end)

      {:ok, 1} =
        Store.process_pending(10, fn [pending] ->
          assert pending.id == second.id
          publish_all([pending])
        end)
    end

    test "a failed first event holds back the second of the same message" do
      first = row("m1", "new_message")
      second = row("m1", "message_updated", %{apply: nil})
      Enum.each([first, second], &Store.insert([&1]))

      {:ok, 0} = Store.process_pending(10, fn [p] -> [{p.id, {:retry, :not_connected}}] end)

      {:ok, 1} =
        Store.process_pending(10, fn [pending] ->
          assert pending.id == first.id
          publish_all([pending])
        end)
    end

    test "events without a message do not hold each other back" do
      rows = for _ <- 1..3, do: row(nil, "access_revoked", %{message_id: nil, apply: nil})
      Enum.each(rows, &Store.insert([&1]))

      assert {:ok, 3} = Store.process_pending(10, &publish_all/1)
    end

    test "two pollers at once never take the same row" do
      rows = for n <- 1..6, do: row("m#{n}")
      Store.insert(rows)
      test_pid = self()

      holder =
        Task.async(fn ->
          Store.process_pending(3, fn pending ->
            send(test_pid, {:holding, Enum.map(pending, & &1.id)})

            receive do
              :release -> publish_all(pending)
            end
          end)
        end)

      assert_receive {:holding, held}, 2_000
      assert length(held) == 3

      assert {:ok, 3} =
               Store.process_pending(10, fn pending ->
                 ids = Enum.map(pending, & &1.id)
                 assert Enum.all?(ids, &(&1 not in held))
                 publish_all(pending)
               end)

      send(holder.pid, :release)
      assert {:ok, 3} = Task.await(holder)
      assert {:ok, 0} = Store.process_pending(10, fn [] -> [] end)
    end

    test "an instance that dies mid-batch leaves its rows pending for another one" do
      r = row("m1")
      :ok = Store.insert([r])

      assert {:error, %RuntimeError{message: "instance went away"}} =
               Store.process_pending(10, fn _pending -> raise "instance went away" end)

      assert %{published_at: nil, attempts: 0} = fetch(r.id)

      assert {:ok, 1} = Store.process_pending(10, &publish_all/1)
    end

    test "a failed attempt counts and remembers why" do
      r = row("m1")
      :ok = Store.insert([r])

      {:ok, 0} = Store.process_pending(10, fn [p] -> [{p.id, {:error, {:invalid, :date}}}] end)

      stored = fetch(r.id)
      assert stored.attempts == 1
      assert stored.last_error =~ "invalid"
      assert stored.published_at == nil
      assert stored.payload != nil
    end

    test "an unavailable broker is retried without using up attempts" do
      r = row("m1")
      :ok = Store.insert([r])

      for _ <- 1..15 do
        {:ok, 0} = Store.process_pending(10, fn [p] -> [{p.id, {:retry, :not_connected}}] end)
      end

      stored = fetch(r.id)
      assert stored.attempts == 0
      assert stored.last_error =~ "not_connected"
      assert {:ok, 1} = Store.process_pending(10, &publish_all/1)
    end

    test "a row that keeps failing is set aside after 10 attempts, but is kept" do
      r = row("m1")
      :ok = Store.insert([r])

      for _ <- 1..10 do
        {:ok, 0} = Store.process_pending(10, fn [p] -> [{p.id, {:error, :boom}}] end)
      end

      assert {:ok, 0} = Store.process_pending(10, fn [] -> [] end)
      assert %{attempts: 10, published_at: nil, payload: payload} = fetch(r.id)
      assert payload != nil
    end

    test "the content of an event that was published does not stay in the table" do
      r = row("m1")
      :ok = Store.insert([r])
      {:ok, 1} = Store.process_pending(10, &publish_all/1)

      %Postgrex.Result{rows: rows} =
        Postgrex.query!(
          Postgres,
          "SELECT row_to_json(o)::text FROM #{@schema}.outbox_events o",
          []
        )

      refute rows |> List.flatten() |> Enum.join() =~ "secreto"
    end
  end
else
  defmodule Messaging.Outbox.Store.PostgresTest do
    use ExUnit.Case

    test "skipped: set DATABASE_HOST to run this against a real Postgres" do
      IO.puts("\nSkipping Outbox.Store.Postgres test: DATABASE_HOST not set.\n")
    end
  end
end
