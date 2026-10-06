defmodule MessagingWeb.ApiSpecTest do
  use ExUnit.Case, async: true

  test "spec/0 builds a resolvable OpenAPI document for every route" do
    spec = MessagingWeb.ApiSpec.spec()

    assert %OpenApiSpex.OpenApi{} = spec
    assert Map.has_key?(spec.paths, "/livez")
    assert Map.has_key?(spec.paths, "/readyz")
    assert Map.has_key?(spec.paths, "/v1/channels/{channel_id}/messages")
    assert Map.has_key?(spec.paths, "/v1/socket-tickets")
    assert %{get: %OpenApiSpex.Operation{}} = spec.paths["/v1/conversations"]
    assert %{post: %OpenApiSpex.Operation{}} = spec.paths["/v1/conversations/{id}/read"]

    assert %{patch: %OpenApiSpex.Operation{}, delete: %OpenApiSpex.Operation{}} =
             spec.paths["/v1/channels/{channel_id}/messages/{message_id}"]
  end
end
