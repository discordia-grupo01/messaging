defmodule MessagingWeb.ErrorJSONTest do
  use ExUnit.Case, async: true

  test "renders 404.json using the project-wide error envelope" do
    assert MessagingWeb.ErrorJSON.render("404.json", %{}) == %{
             error: %{code: "404", message: "Not Found", details: %{}}
           }
  end

  test "renders 500.json using the project-wide error envelope" do
    assert MessagingWeb.ErrorJSON.render("500.json", %{}) == %{
             error: %{code: "500", message: "Internal Server Error", details: %{}}
           }
  end
end
