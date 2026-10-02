defmodule Messaging.Events.Backoff do
  @initial 1_000
  @max 30_000

  def initial, do: @initial
  def next(backoff), do: min(backoff * 2, @max)
end
