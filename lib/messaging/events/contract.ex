defmodule Messaging.Events.Contract do
  require Logger

  alias Discordia.EventsContract.Validator

  @spec check(String.t(), map() | binary()) :: :ok | {:error, [String.t()]}
  def check(routing_key, event) do
    case mode() do
      :off -> :ok
      :warn -> validate(routing_key, event)
    end
  end

  defp validate(routing_key, event) do
    do_validate(routing_key, event)
  rescue
    error ->
      Logger.warning("event_contract_check_failed",
        routing_key: routing_key,
        reason: Exception.message(error)
      )

      :ok
  end

  defp do_validate(routing_key, event) do
    case Validator.validate(routing_key, event) do
      :ok ->
        :ok

      {:error, :unknown_event} ->
        :ok

      {:error, reasons} ->
        Logger.warning("event_contract_violation",
          routing_key: routing_key,
          reason: reasons |> Enum.take(5) |> Enum.join("; ")
        )

        {:error, reasons}
    end
  end

  defp mode, do: Application.get_env(:messaging, :event_contract_check, :warn)
end
