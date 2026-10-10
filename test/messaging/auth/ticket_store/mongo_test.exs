mongo_url = System.get_env("MONGO_URL")

if mongo_url do
  defmodule Messaging.Auth.TicketStore.MongoTest do
    use ExUnit.Case, async: false

    alias Messaging.Auth.TicketStore.Mongo, as: Store

    defp doc(id),
      do: %{
        "_id" => id,
        "user_id" => "user-1",
        "expires_at" => DateTime.utc_now()
      }

    test "take/1 returns the stored ticket once and deletes it (single use)" do
      id = "ticket-" <> Messaging.UUID.generate()

      assert :ok = Store.put(doc(id))
      assert {:ok, %{"_id" => ^id, "user_id" => "user-1"}} = Store.take(id)
      assert {:ok, nil} = Store.take(id)
    end

    test "take/1 returns nil for an unknown ticket" do
      assert {:ok, nil} = Store.take("missing-" <> Messaging.UUID.generate())
    end

    test "put/1 creates the TTL index so expired tickets are cleaned up by Mongo" do
      assert :ok = Store.put(doc("ticket-" <> Messaging.UUID.generate()))

      {:ok, indexes} =
        Mongo.command(Messaging.Mongo, listIndexes: "socket_tickets")
        |> then(fn {:ok, %{"cursor" => %{"firstBatch" => batch}}} -> {:ok, batch} end)

      assert Enum.any?(indexes, &(&1["name"] == "socket_tickets_expires_at_ttl"))
    end
  end
else
  defmodule Messaging.Auth.TicketStore.MongoTest do
    use ExUnit.Case

    test "skipped: set MONGO_URL to run this against a real Mongo instance" do
      IO.puts("\nSkipping TicketStore.Mongo test: MONGO_URL not set.\n")
    end
  end
end
