defmodule MessagingWeb.ErrorJSON do
  def render(template, _assigns) do
    code = template |> String.trim_trailing(".json") |> String.upcase()

    %{
      error: %{
        code: code,
        message: Phoenix.Controller.status_message_from_template(template),
        details: %{}
      }
    }
  end
end
