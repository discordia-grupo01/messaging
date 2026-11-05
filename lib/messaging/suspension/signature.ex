defmodule Messaging.Suspension.Signature do
  @moduledoc """
  HMAC signature of the `admin.*` events. The contract (the Go `Sign` in
  `events-contract/admin`) is
  `hex(HMAC-SHA256(secret, routing_key \n event_id \n subject_id \n version \n occurred_at))`,
  where the subject is the `user_id` of the account events and the `server_id`
  of the server events.

  `occurred_at` has to be the exact string that came in the JSON: admin signs it
  already in UTC, and parsing and formatting it again could change its digits.
  """

  @type signed ::
          %{
            routing_key: String.t(),
            event_id: String.t(),
            user_id: String.t(),
            version: integer(),
            occurred_at: String.t()
          }
          | %{
              routing_key: String.t(),
              event_id: String.t(),
              server_id: String.t(),
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

  defp fields(%{routing_key: routing_key, event_id: event_id, version: version} = event)
       when is_binary(routing_key) and is_binary(event_id) and is_integer(version) do
    with {:ok, subject} <- subject(event),
         %{occurred_at: occurred_at} when is_binary(occurred_at) <- event do
      {:ok,
       %{
         routing_key: routing_key,
         event_id: event_id,
         subject: subject,
         version: version,
         occurred_at: occurred_at
       }}
    else
      _invalid -> :error
    end
  end

  defp fields(_event), do: :error

  # An event names exactly one subject: a user or a server.
  defp subject(%{user_id: user_id, server_id: _server_id}) when is_binary(user_id), do: :error
  defp subject(%{user_id: user_id}) when is_binary(user_id), do: {:ok, user_id}
  defp subject(%{server_id: server_id}) when is_binary(server_id), do: {:ok, server_id}
  defp subject(_event), do: :error

  defp text(%{routing_key: routing_key, event_id: event_id, version: version} = signed) do
    Enum.join(
      [routing_key, event_id, subject!(signed), Integer.to_string(version), signed.occurred_at],
      "\n"
    )
  end

  defp subject!(%{subject: subject}), do: subject
  defp subject!(signed), do: signed |> subject() |> elem(1)
end
