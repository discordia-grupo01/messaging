defmodule MyAppWeb.UserSocket do
  @moduledoc "Punto de entrada de los websockets. Autentica la conexion y enruta a los channels."
  use Phoenix.Socket

  channel "my_entity:*", MyAppWeb.MyEntityChannel

  @impl true
  def connect(_params, socket, _connect_info) do
    # TODO: validar el JWT recibido en params antes de aceptar la conexion
    {:ok, socket}
  end

  @impl true
  def id(_socket), do: nil
end
