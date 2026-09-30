defmodule MessagingWeb.ApiSpecTest do
  use ExUnit.Case, async: true

  test "spec/0 builds a resolvable OpenAPI document for every route" do
    spec = MessagingWeb.ApiSpec.spec()

    assert %OpenApiSpex.OpenApi{} = spec
    assert Map.has_key?(spec.paths, "/livez")
    assert Map.has_key?(spec.paths, "/readyz")
    assert Map.has_key?(spec.paths, "/v1/channels/{channel_id}/messages")
  end
end
