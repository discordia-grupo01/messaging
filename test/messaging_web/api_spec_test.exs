defmodule MessagingWeb.ApiSpecTest do
  use ExUnit.Case, async: true

  test "spec/0 builds a resolvable OpenAPI document for every route" do
    spec = MessagingWeb.ApiSpec.spec()

    assert %OpenApiSpex.OpenApi{} = spec
    assert Map.has_key?(spec.paths, "/livez")
    assert Map.has_key?(spec.paths, "/readyz")
    assert Map.has_key?(spec.paths, "/v1/channels/{channel_id}/messages")
    assert Map.has_key?(spec.paths, "/v1/socket-tickets")

    assert %{get: %OpenApiSpex.Operation{}, post: %OpenApiSpex.Operation{}} =
             spec.paths["/v1/blocks"]

    assert %{delete: %OpenApiSpex.Operation{}} = spec.paths["/v1/blocks/{user_id}"]
    assert spec.paths["/v1/blocks/{user_id}"].put == nil

    assert %{get: %OpenApiSpex.Operation{}} = spec.paths["/v1/conversations"]
    assert %{post: %OpenApiSpex.Operation{}} = spec.paths["/v1/conversations/{id}/read"]

    assert %{patch: %OpenApiSpex.Operation{}, delete: %OpenApiSpex.Operation{}} =
             spec.paths["/v1/channels/{channel_id}/messages/{message_id}"]

    assert %{get: %OpenApiSpex.Operation{}} = spec.paths["/v1/mentions"]

    assert %{post: %OpenApiSpex.Operation{}} =
             spec.paths["/v1/channels/{channel_id}/mentions/read"]

    assert %{get: %OpenApiSpex.Operation{}} =
             spec.paths["/v1/servers/{server_id}/messages/search"]
  end
end
