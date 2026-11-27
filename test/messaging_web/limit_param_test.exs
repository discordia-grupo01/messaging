defmodule MessagingWeb.LimitParamTest do
  use ExUnit.Case, async: true

  alias MessagingWeb.LimitParam

  test "a missing limit is not an error" do
    assert LimitParam.parse(nil) == {:ok, nil}
  end

  test "an integer is parsed" do
    assert LimitParam.parse("25") == {:ok, 25}
    assert LimitParam.parse("-1") == {:ok, -1}
  end

  test "anything that is not a whole integer is rejected" do
    for bad <- ["", ":", "abc", "12abc", "1.5", " 3", ["1"], %{"a" => "1"}] do
      assert LimitParam.parse(bad) == {:error, :invalid_payload}
    end
  end
end
