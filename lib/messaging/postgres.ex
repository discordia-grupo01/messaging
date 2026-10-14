defmodule Messaging.Postgres do
  @schema_format ~r/\A[a-z_][a-z0-9_]*\z/

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts), do: Postgrex.child_spec(options() ++ [name: __MODULE__])

  @spec options() :: keyword()
  def options do
    settings = Application.get_env(:messaging, :postgres, [])

    [
      hostname: settings[:host] || "localhost",
      port: settings[:port] || 5432,
      database: settings[:database] || "messaging",
      username: settings[:username] || "postgres",
      password: settings[:password] || "postgres",
      pool_size: settings[:pool_size] || 5
    ] ++ ssl(settings[:sslmode], settings[:host])
  end

  @spec schema() :: String.t()
  def schema do
    schema = Application.get_env(:messaging, :postgres, [])[:schema] || "public"

    if Regex.match?(@schema_format, schema),
      do: schema,
      else: raise(ArgumentError, "DATABASE_SCHEMA is not a valid schema name: #{inspect(schema)}")
  end

  @spec ping() :: :ok | {:error, term()}
  def ping do
    case Postgrex.query(__MODULE__, "SELECT 1", [], timeout: 3_000) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp ssl("require", _host), do: [ssl: [verify: :verify_none]]

  defp ssl("verify-full", host) do
    [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: String.to_charlist(host || "localhost"),
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]
  end

  defp ssl(_disabled, _host), do: []
end
