defmodule Messaging.PostgresTest do
  use ExUnit.Case, async: false

  alias Messaging.Postgres

  setup do
    previous = Application.get_env(:messaging, :postgres)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:messaging, :postgres, previous),
        else: Application.delete_env(:messaging, :postgres)
    end)
  end

  defp configure(overrides) do
    Application.put_env(
      :messaging,
      :postgres,
      Keyword.merge(
        [
          host: "db.example.com",
          port: 6543,
          database: "postgres",
          username: "postgres.abc",
          password: "secret",
          sslmode: "disable",
          schema: "messaging",
          pool_size: 7
        ],
        overrides
      )
    )
  end

  test "options come from the configuration" do
    configure([])

    options = Postgres.options()

    assert options[:hostname] == "db.example.com"
    assert options[:port] == 6543
    assert options[:database] == "postgres"
    assert options[:username] == "postgres.abc"
    assert options[:password] == "secret"
    assert options[:pool_size] == 7
    refute Keyword.has_key?(options, :ssl)
  end

  test "defaults let a local database work with no configuration" do
    Application.delete_env(:messaging, :postgres)

    options = Postgres.options()

    assert options[:hostname] == "localhost"
    assert options[:port] == 5432
    assert Postgres.schema() == "public"
  end

  test "sslmode require encrypts the connection without verifying the certificate" do
    configure(sslmode: "require")

    assert [verify: :verify_none] = Postgres.options()[:ssl]
  end

  test "sslmode verify-full verifies the certificate and the host name" do
    configure(sslmode: "verify-full")

    ssl = Postgres.options()[:ssl]

    assert ssl[:verify] == :verify_peer
    assert ssl[:server_name_indication] == ~c"db.example.com"
    assert is_list(ssl[:cacerts])
    assert Keyword.has_key?(ssl, :customize_hostname_check)
  end

  test "the schema name is validated, because it ends up inside SQL" do
    configure(schema: "messaging")
    assert Postgres.schema() == "messaging"

    for bad <- ["", "Messaging", "a-b", "a;drop table x", "public.outbox", "1abc", "a b", "a\""] do
      configure(schema: bad)

      assert_raise ArgumentError, ~r/not a valid schema name/, fn -> Postgres.schema() end
    end
  end

  test "ping/0 reports an error instead of crashing when the pool is not running" do
    assert {:error, _reason} = Postgres.ping()
  end

  describe "with a database that is down" do
    alias Messaging.Outbox.Store.Postgres, as: Store

    setup do
      configure(host: "127.0.0.1", port: 1)
      start_supervised!(Postgres)
      :ok
    end

    @tag capture_log: true
    test "recording an event is an error the caller can handle, not a crash" do
      row = %{
        id: Messaging.UUID.generate_v7(),
        event: "new_message",
        topic: "channel:c",
        payload: %{}
      }

      assert {:error, _reason} = Store.insert([row])
    end

    @tag capture_log: true
    test "polling is an error the poller can log, not a crash" do
      assert {:error, _reason} = Store.process_pending(10, fn _rows -> [] end)
    end

    @tag capture_log: true
    test "ping/0 says the database is not there" do
      assert {:error, _reason} = Postgres.ping()
    end
  end
end
