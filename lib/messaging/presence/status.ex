defmodule Messaging.Presence.Status do
  @choices ["online", "idle", "dnd", "invisible"]

  @type choice :: String.t()
  @type visible :: String.t()
  @type doc :: map()
  @type change ::
          {:connect, String.t(), String.t()}
          | {:disconnect, String.t()}
          | {:activity, String.t(), boolean()}
          | {:set_manual, choice()}
          | {:drop_instance, String.t()}

  @spec choices() :: [choice()]
  def choices, do: @choices

  @spec valid_choice?(term()) :: boolean()
  def valid_choice?(choice), do: choice in @choices

  @spec default_choice() :: choice()
  def default_choice, do: "online"

  @spec manual(doc() | nil) :: choice()
  def manual(nil), do: default_choice()
  def manual(doc), do: Map.get(doc, "manual") || default_choice()

  @spec version(doc() | nil) :: non_neg_integer()
  def version(nil), do: 0
  def version(doc), do: Map.get(doc, "version") || 0

  @spec effective(doc() | nil) :: visible()
  def effective(nil), do: "offline"

  def effective(doc) do
    connections = Map.get(doc, "connections") || []
    manual = manual(doc)

    cond do
      connections == [] -> "offline"
      manual == "invisible" -> "offline"
      manual in ["dnd", "idle"] -> manual
      Enum.all?(connections, &(&1["idle"] == true)) -> "idle"
      true -> "online"
    end
  end

  @spec apply_change(doc() | nil, change()) :: doc()
  def apply_change(doc, change) do
    doc = doc || %{"manual" => default_choice(), "connections" => [], "version" => 0}

    doc
    |> update(change)
    |> Map.put("version", version(doc) + 1)
  end

  defp update(doc, {:connect, conn_id, instance_id}),
    do: put_connections(doc, connections(doc) ++ [connection(conn_id, instance_id)])

  defp update(doc, {:disconnect, conn_id}),
    do: put_connections(doc, Enum.reject(connections(doc), &(&1["id"] == conn_id)))

  defp update(doc, {:activity, conn_id, idle}) do
    put_connections(
      doc,
      Enum.map(connections(doc), fn
        %{"id" => ^conn_id} = conn -> Map.put(conn, "idle", idle)
        conn -> conn
      end)
    )
  end

  defp update(doc, {:set_manual, choice}), do: Map.put(doc, "manual", choice)

  defp update(doc, {:drop_instance, instance_id}),
    do: put_connections(doc, Enum.reject(connections(doc), &(&1["instance"] == instance_id)))

  @doc "A new connection, active."
  @spec connection(String.t(), String.t()) :: map()
  def connection(conn_id, instance_id),
    do: %{"id" => conn_id, "instance" => instance_id, "idle" => false}

  defp connections(doc), do: Map.get(doc, "connections") || []
  defp put_connections(doc, connections), do: Map.put(doc, "connections", connections)
end
