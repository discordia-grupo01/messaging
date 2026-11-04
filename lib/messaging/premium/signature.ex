defmodule Messaging.Premium.Signature do
  @moduledoc """
  HMAC signature of `billing.premium_updated`, ported from
  `events-contract/billing/events.ex`. The signed text is

      routing_key \\n event_id \\n user_id \\n active \\n premium_until \\n renews \\n version \\n occurred_at

  `premium_until` and `occurred_at` have to be the exact strings that came in the
  JSON: parsing and formatting them again could change their digits. A null
  `premium_until` is signed as the empty string.
  """

  @routing_key "billing.premium_updated"

  @spec sign(map(), String.t()) :: String.t()
  def sign(event, secret) when is_binary(secret) do
    :hmac
    |> :crypto.mac(:sha256, secret, text(event))
    |> Base.encode16(case: :lower)
  end

  @spec verify(map(), String.t() | nil) :: boolean()
  def verify(_event, secret) when secret in [nil, ""], do: false

  def verify(%{"signature" => signature} = event, secret)
      when is_binary(signature) and signature != "" do
    Plug.Crypto.secure_compare(sign(event, secret), signature)
  end

  def verify(_event, _secret), do: false

  defp text(event) do
    Enum.join(
      [
        @routing_key,
        event["event_id"],
        event["user_id"],
        to_string(event["active"]),
        event["premium_until"] || "",
        to_string(event["renews"]),
        Integer.to_string(event["version"]),
        event["occurred_at"]
      ],
      "\n"
    )
  end
end
