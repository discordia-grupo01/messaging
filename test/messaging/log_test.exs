defmodule Messaging.LogTest do
  use ExUnit.Case, async: true

  alias Messaging.Log

  test "atoms and short tuples are kept, as they are the useful part of a reason" do
    assert Log.reason(:timeout) == ":timeout"
    assert Log.reason({:unexpected_status, 500}) == "{:unexpected_status, 500}"
  end

  test "an exception only shows its module and its atom reason, never its payload" do
    assert Log.reason(%Req.TransportError{reason: :timeout}) =~
             "Req.TransportError reason=timeout"

    {:error, error} = Jason.decode("{\"content\": \"private text\" oops")
    reason = Log.reason(error)

    assert reason =~ "Jason.DecodeError"
    refute reason =~ "private text"
  end

  test "an exception nested in a tuple is sanitized too" do
    {:error, error} = Jason.decode("private text not json")

    refute Log.reason({:error, error}) =~ "private text"
  end

  test "long text and long lists are cut" do
    assert String.length(Log.reason(String.duplicate("a", 5_000))) < 200
    refute Log.reason(Enum.to_list(1..100)) =~ "100"
  end
end
