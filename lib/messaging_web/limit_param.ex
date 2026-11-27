defmodule MessagingWeb.LimitParam do
  @spec parse(term()) :: {:ok, integer() | nil} | {:error, :invalid_payload}
  def parse(nil), do: {:ok, nil}

  def parse(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} -> {:ok, n}
      _invalid -> {:error, :invalid_payload}
    end
  end

  def parse(_other), do: {:error, :invalid_payload}
end
