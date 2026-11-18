defmodule MessagingWeb.ApiErrorTest do
  use ExUnit.Case, async: true

  alias MessagingWeb.ApiError

  test "payload/1 builds the project-wide error envelope" do
    assert %{error: %{code: "EMPTY_CONTENT", message: _message, details: %{}}} =
             ApiError.payload(:empty_content)
  end

  test "payload/2 carries through the details map" do
    assert %{error: %{details: %{limit: 2_000}}} =
             ApiError.payload(:message_too_long, %{limit: 2_000})
  end

  test "http_status/1 maps each reason to the right status" do
    assert ApiError.http_status(:forbidden) == 403
    assert ApiError.http_status(:channel_not_found) == 404
    assert ApiError.http_status(:empty_content) == 400
    assert ApiError.http_status(:message_too_long) == 400
    assert ApiError.http_status(:ticket_unavailable) == 503
    assert ApiError.http_status(:not_message_author) == 403
    assert ApiError.http_status(:message_delete_denied) == 403
    assert ApiError.http_status(:recipient_not_found) == 404
    assert ApiError.http_status(:users_unavailable) == 503
    assert ApiError.http_status(:cannot_message_self) == 400
    assert ApiError.http_status(:cannot_block_self) == 400
    assert ApiError.http_status(:user_not_found) == 404
    assert ApiError.http_status(:user_blocked) == 403
    assert ApiError.http_status(:dm_not_delivered) == 403
    assert ApiError.http_status(:message_not_found) == 404
    assert ApiError.http_status(:invalid_payload) == 400
    assert ApiError.http_status(:invalid_search_query) == 400
    assert ApiError.http_status(:not_server_member) == 403
    assert ApiError.http_status(:search_unavailable) == 503
  end

  test "describe/1 covers every reason with a non-empty code and message" do
    for reason <- [
          :empty_content,
          :message_too_long,
          :forbidden,
          :channel_not_found,
          :channel_not_text,
          :invalid_cursor,
          :ticket_unavailable,
          :message_not_found,
          :not_message_author,
          :message_delete_denied,
          :cannot_message_self,
          :cannot_block_self,
          :user_not_found,
          :user_blocked,
          :dm_not_delivered,
          :recipient_not_found,
          :users_unavailable,
          :invalid_payload,
          :invalid_search_query,
          :not_server_member,
          :search_unavailable
        ] do
      assert {code, message} = ApiError.describe(reason)
      assert code != ""
      assert message != ""
    end
  end

  test "INVALID_PAYLOAD was renamed to INVALID_BODY" do
    assert {"INVALID_BODY", _message} = ApiError.describe(:invalid_payload)
  end

  test "every code is SCREAMING_SNAKE and details is always a map" do
    reasons = [
      :unauthorized,
      {:unauthorized, "otro mensaje"},
      {:forbidden, "no podés"},
      {:invalid_query, "limit"},
      :service_unavailable,
      :invalid_payload,
      {:banned_word, ["x"]},
      :empty_content
    ]

    for reason <- reasons do
      assert %{error: %{code: code, message: message, details: details}} =
               ApiError.payload(reason)

      assert code =~ ~r/^[A-Z][A-Z0-9_]*$/
      assert is_binary(message) and message != ""
      assert is_map(details)
    end
  end

  test "authorization reasons map to 401 and 403" do
    assert ApiError.http_status(:unauthorized) == 401
    assert ApiError.http_status({:unauthorized, "x"}) == 401
    assert ApiError.http_status({:forbidden, "x"}) == 403
    assert ApiError.http_status({:invalid_query, "x"}) == 400
  end

  describe "unknown errors from a dependency" do
    test "a raw Mongo.Error does not crash the mapper and does not leak internals" do
      error = %Mongo.Error{message: "connection refused to 10.0.0.5:27017"}

      assert ApiError.http_status(error) == 503

      assert %{error: %{code: "SERVICE_UNAVAILABLE", message: message, details: %{}}} =
               ApiError.payload(error)

      refute message =~ "10.0.0.5"
    end

    test "an unmapped atom or tuple falls into the same catch-all" do
      for unknown <- [:timeout, {:error, :econnrefused}, "boom"] do
        assert ApiError.http_status(unknown) == 503
        assert %{error: %{code: "SERVICE_UNAVAILABLE"}} = ApiError.payload(unknown)
      end
    end
  end

  test "code_for_status/1 follows the common catalogue" do
    assert ApiError.code_for_status(404) == "NOT_FOUND"
    assert ApiError.code_for_status(500) == "INTERNAL_ERROR"
    assert ApiError.code_for_status(504) == "INTERNAL_ERROR"
  end
end
