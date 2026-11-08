defmodule Messaging.Log.ShipperHandler do
  alias Messaging.Log.JSONFormatter
  alias Messaging.Log.Shipper

  @handler_id :messaging_log_shipper

  @spec handler_id() :: atom()
  def handler_id, do: @handler_id

  @spec attach() :: :ok | {:error, term()}
  def attach do
    detach()

    case :logger.add_handler(@handler_id, __MODULE__, %{config: %{metadata: metadata_keys()}}) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec detach() :: :ok
  def detach do
    _ = :logger.remove_handler(@handler_id)
    :ok
  end

  @spec log(:logger.log_event(), :logger.handler_config()) :: :ok
  def log(%{level: level, msg: msg, meta: meta}, %{config: %{metadata: keys}}) do
    if own_event?(meta) do
      :ok
    else
      level
      |> to_entry(message(msg, meta), meta, keys)
      |> Shipper.enqueue()
    end
  rescue
    _error -> :ok
  end

  defp to_entry(level, message, meta, keys) do
    metadata = meta |> Map.take(keys) |> Map.to_list()
    entry = JSONFormatter.entry(level, message, metadata)

    attributes =
      entry
      |> Map.drop([:time, :message, :service])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new(fn {key, value} -> {attribute_name(key), value} end)

    %{
      timestamp: timestamp(meta),
      message: entry.message,
      attributes: attributes
    }
  end

  defp attribute_name(:trace_id), do: "trace.id"
  defp attribute_name(:span_id), do: "span.id"
  defp attribute_name(key), do: Atom.to_string(key)

  defp timestamp(%{time: micros}) when is_integer(micros), do: div(micros, 1_000)
  defp timestamp(_meta), do: System.system_time(:millisecond)

  defp own_event?(%{domain: domain}) when is_list(domain), do: :log_shipper in domain
  defp own_event?(_meta), do: false

  defp message({:string, text}, _meta), do: IO.chardata_to_string(text)

  defp message({:report, report}, %{report_cb: callback}) when is_function(callback, 1) do
    case callback.(report) do
      {format, args} -> format |> :io_lib.format(args) |> IO.chardata_to_string()
      other -> inspect(other, limit: 20, printable_limit: 500)
    end
  end

  defp message({:report, report}, _meta), do: inspect(report, limit: 20, printable_limit: 500)

  defp message({format, args}, _meta),
    do: format |> :io_lib.format(args) |> IO.chardata_to_string()

  defp metadata_keys do
    :logger
    |> Application.get_env(:console, [])
    |> Keyword.get(:metadata, [])
  end
end
