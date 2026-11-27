defmodule MessagingWeb.Plugs.PathParamLengthTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias MessagingWeb.Plugs.PathParamLength

  test "a path parameter of exactly 64 characters is let through" do
    conn = %{conn(:get, "/") | path_params: %{"id" => String.duplicate("a", 64)}}

    refute PathParamLength.call(conn, []).halted
  end

  test "a path parameter longer than 64 characters halts the request with a 400" do
    conn = %{conn(:get, "/") | path_params: %{"user_id" => String.duplicate("a", 65)}}
    result = PathParamLength.call(conn, [])

    assert result.halted
    assert result.status == 400
  end

  test "a request without path parameters is let through" do
    refute PathParamLength.call(conn(:get, "/"), []).halted
  end

  test "counts characters, not bytes: 64 four-byte characters are let through" do
    conn = %{
      Plug.Test.conn(:get, "/")
      | path_params: %{"id" => String.duplicate("\u{10000}", 64)}
    }

    refute MessagingWeb.Plugs.PathParamLength.call(conn, []).halted
  end
end
