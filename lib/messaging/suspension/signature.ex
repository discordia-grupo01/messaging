defmodule Messaging.Suspension.Signature do
  @moduledoc """
  HMAC signature of the `admin.*` events. The contract (the Go `Sign` in
  `events-contract/admin`) is
  `hex(HMAC-SHA256(secret, routing_key \n event_id \n user_id \n version \n occurred_at))`.

  `occurred_at` has to be the exact string that came in the JSON: admin signs it
  already in UTC, and parsing and formatting it again could change its digits.
  """

  @type signed :: %{
          routing_key: String.t(),
          event_id: String.t(),
          user_id: String.t(),
          version: integer(),
          occurred_at: String.t()
        }

  @spec sign(signed(), String.t()) :: String.t()
  def sign(signed, secret) when is_binary(secret) do
    :hmac
    |> :crypto.mac(:sha256, secret, text(signed))
    |> Base.encode16(case: :lower)
  end

  @spec verify(map(), String.t() | nil) :: boolean()
  def verify(_event, secret) when secret in [nil, ""], do: false

  def verify(%{signature: signature} = event, secret)
      when is_binary(signature) and signature != "" do
    case fields(event) do
      {:ok, signed} -> Plug.Crypto.secure_compare(sign(signed, secret), signature)
      :error -> false
    end
  end

  def verify(_event, _secret), do: false

  defp fields(%{
         routing_key: routing_key,
         event_id: event_id,
         user_id: user_id,
         version: version,
         occurred_at: occurred_at
       })
       when is_binary(routing_key) and is_binary(event_id) and is_binary(user_id) and
              is_integer(version) and is_binary(occurred_at) do
    {:ok,
     %{
       routing_key: routing_key,
       event_id: event_id,
       user_id: user_id,
       version: version,
       occurred_at: occurred_at
     }}
  end

  defp fields(_event), do: :error

  defp text(%{
         routing_key: routing_key,
         event_id: event_id,
         user_id: user_id,
         version: version,
         occurred_at: occurred_at
       }) do
    Enum.join([routing_key, event_id, user_id, Integer.to_string(version), occurred_at], "\n")
  end
end
