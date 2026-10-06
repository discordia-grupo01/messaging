defmodule Messaging.Log.JSONFormatter do
  @service "messaging"
  @internal_keys [
    :pid,
    :gl,
    :time,
    :mfa,
    :file,
    :line,
    :domain,
    :application,
    :erl_level,
    :crash_reason,
    :initial_call,
    :registered_name
  ]
  @sensitive_keys [
    :content,
    :to,
    :ticket,
    :token,
    :jwt,
    :raw_jwt,
    :password,
    :authorization,
    :secret
  ]
  @max_text 2_000

  @spec format(Logger.level(), Logger.message(), term(), keyword()) :: IO.chardata()
  def format(level, message, _timestamp, metadata) do
    entry =
      metadata
      |> fields()
      |> Map.merge(%{
        time: DateTime.utc_now() |> DateTime.to_iso8601(),
        level: level,
        service: @service,
        message: text(message)
      })

    [Jason.encode_to_iodata!(entry), ?\n]
  rescue
    _error ->
      [~s({"level":"error","service":"messaging","message":"log_format_failed"}), ?\n]
  end

  defp fields(metadata) do
    for {key, value} <- metadata, key not in @internal_keys, into: %{} do
      {key, if(key in @sensitive_keys, do: "[FILTERED]", else: encode(value))}
    end
  end

  defp encode(value) when is_binary(value) do
    if String.valid?(value), do: String.slice(value, 0, @max_text), else: inspect(value)
  end

  defp encode(value) when is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp encode(value) when is_atom(value), do: Atom.to_string(value)
  defp encode(value), do: inspect(value, limit: 10, printable_limit: 200)

  defp text(message) do
    message |> IO.chardata_to_string() |> String.slice(0, @max_text)
  rescue
    _error -> inspect(message, limit: 10, printable_limit: 200)
  end
end
