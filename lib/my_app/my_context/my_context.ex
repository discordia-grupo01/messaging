defmodule MyApp.MyContext do
  @moduledoc """
  API publica del context de ejemplo. Todo lo que entra o sale de este dominio
  de negocio pasa por aca -- el resto de la app (controllers, channels) nunca
  accede directo a MyEntity ni a la base de datos.

  Renombrar MyContext por el nombre real del context al usarlo (ej. Messaging).
  """

  alias MyApp.MyContext.MyEntity

  @doc "Reemplazar por la consulta real (ej. a Mongo o Postgres)."
  def get_my_entity(_id), do: {:error, :not_implemented}

  @doc "Reemplazar por el listado real, con el filtro que corresponda."
  def list_my_entities(_filter), do: []

  @doc "Ejemplo de validacion minima -- reemplazar por la real."
  def create_my_entity(attrs) do
    if Map.get(attrs, "id") || Map.get(attrs, :id) do
      {:ok, struct(MyEntity, attrs)}
    else
      {:error, :missing_id}
    end
  end
end
