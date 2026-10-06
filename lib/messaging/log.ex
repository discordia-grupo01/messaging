defmodule Messaging.Log do
  @max_text 120

  @spec reason(term()) :: String.t()
  def reason(reason), do: reason |> sanitize() |> inspect(limit: 6, printable_limit: @max_text)

  defp sanitize(%module{__exception__: true} = exception) do
    [inspect(module) | exception_details(exception)] |> Enum.join(" ")
  end

  defp sanitize(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&sanitize/1) |> List.to_tuple()

  defp sanitize(list) when is_list(list), do: list |> Enum.take(6) |> Enum.map(&sanitize/1)
  defp sanitize(text) when is_binary(text), do: String.slice(text, 0, @max_text)
  defp sanitize(other), do: other

  defp exception_details(exception) do
    for {key, value} <- [reason: Map.get(exception, :reason), code: Map.get(exception, :code)],
        (is_atom(value) and not is_nil(value)) or is_integer(value) do
      "#{key}=#{value}"
    end
  end
end
