defmodule MyAppWeb.MyEntityController do
  @moduledoc """
  Recibe el request HTTP, llama al context, devuelve la respuesta.
  Nunca accede directo a MyEntity ni al Repo -- siempre pasa por MyApp.MyContext.*
  """
  use Phoenix.Controller, formats: [:json]

  alias MyApp.MyContext

  def index(conn, _params) do
    entities = MyContext.list_my_entities(%{})
    json(conn, entities)
  end

  def create(conn, params) do
    case MyContext.create_my_entity(params) do
      {:ok, entity} -> conn |> put_status(:created) |> json(entity)
      {:error, reason} -> conn |> put_status(:bad_request) |> json(%{error: reason})
    end
  end
end
