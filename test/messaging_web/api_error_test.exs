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
    assert ApiError.http_status(:message_not_found) == 404
    assert ApiError.http_status(:invalid_payload) == 400
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
          :invalid_payload
        ] do
      assert {code, message} = ApiError.describe(reason)
      assert code != ""
      assert message != ""
    end
  end
end
