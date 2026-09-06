defmodule MyApp.MyContext.MyEntity do
  @moduledoc """
  Struct de la entidad de ejemplo. Sin Ecto (ej. con Mongo), es un struct comun.
  Con Ecto (Postgres), esto seria un `schema`.

  Renombrar MyEntity por el nombre real (ej. Message, Role, Invoice) al usarlo.
  """
  defstruct [:id, :inserted_at]
end
