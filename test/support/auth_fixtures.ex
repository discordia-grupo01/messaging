defmodule Messaging.AuthFixtures do
  def token_for(user_id) do
    Enum.join(
      [encode(%{"alg" => "HS256", "typ" => "JWT"}), encode(%{"sub" => user_id}), "sig"],
      "."
    )
  end

  def token_with_claims(claims) do
    Enum.join([encode(%{"alg" => "HS256", "typ" => "JWT"}), encode(claims), "sig"], ".")
  end

  def ticket_doc(user_id, opts \\ []) do
    ttl = Keyword.get(opts, :ttl, 30)

    %{
      "_id" => "ticket-hash",
      "user_id" => user_id,
      "expires_at" => DateTime.add(DateTime.utc_now(), ttl, :second)
    }
  end

  defp encode(map), do: map |> Jason.encode!() |> Base.url_encode64(padding: false)
end
