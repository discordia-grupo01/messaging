defmodule Messaging.UUID do
  import Bitwise

  @counter_key {__MODULE__, :v7_counter}
  @max_seq 0xFFF

  @spec init() :: :ok
  def init do
    :persistent_term.put(@counter_key, :atomics.new(1, signed: true))
  end

  @spec generate() :: String.t()
  def generate do
    <<u0::48, _::4, u1::12, _::2, u2::62>> = :crypto.strong_rand_bytes(16)
    format(<<u0::48, 4::4, u1::12, 2::2, u2::62>>)
  end

  @spec generate_v7() :: String.t()
  def generate_v7 do
    {ms, seq} = next_stamp()
    <<_::2, rand::62>> = :crypto.strong_rand_bytes(8)
    format(<<ms::48, 7::4, seq::12, 2::2, rand::62>>)
  end

  defp next_stamp do
    counter = :persistent_term.get(@counter_key)
    last = :atomics.get(counter, 1)
    now = System.os_time(:millisecond)
    {last_ms, last_seq} = {last >>> 12, last &&& @max_seq}

    {ms, seq} =
      cond do
        now > last_ms -> {now, 0}
        last_seq < @max_seq -> {last_ms, last_seq + 1}
        true -> {last_ms + 1, 0}
      end

    case :atomics.compare_exchange(counter, 1, last, ms <<< 12 ||| seq) do
      :ok -> {ms, seq}
      _raced -> next_stamp()
    end
  end

  defp format(<<a::32, b::16, c::16, d::16, e::48>>) do
    [a, b, c, d, e]
    |> Enum.zip([8, 4, 4, 4, 12])
    |> Enum.map_join("-", fn {part, width} ->
      part |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")
    end)
  end
end
