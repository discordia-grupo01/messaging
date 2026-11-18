defmodule MessagingWeb.ErrorJSON do
  @moduledoc """
  Errores del framework (ruta inexistente, JSON mal formado, excepción no manejada) con el sobre
  común de la plataforma. El código sale del status, no del nombre del template.
  """

  alias MessagingWeb.ApiError

  def render(template, _assigns) do
    status = status_from_template(template)

    %{
      error: %{
        code: ApiError.code_for_status(status),
        message: message(status),
        details: %{}
      }
    }
  end

  defp status_from_template(template) do
    case template |> String.trim_trailing(".json") |> Integer.parse() do
      {status, ""} -> status
      _other -> 500
    end
  end

  defp message(400), do: "El pedido no tiene el formato esperado."
  defp message(401), do: "Token inválido o ausente."
  defp message(403), do: "No tenés permiso para realizar esta acción."
  defp message(404), do: "La ruta no existe."
  defp message(405), do: "Método no permitido para esta ruta."
  defp message(406), do: "El formato pedido en Accept no está soportado."
  defp message(413), do: "El pedido es demasiado grande."
  defp message(415), do: "El Content-Type no está soportado."
  defp message(_other), do: "Ocurrió un error inesperado, intentá de nuevo en un momento."
end
