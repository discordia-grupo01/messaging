defmodule MessagingWeb.SearchController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Messaging.Chat
  alias Messaging.Chat.Message
  alias MessagingWeb.ApiError
  alias MessagingWeb.Schemas

  @known_errors [
    :invalid_search_query,
    :invalid_cursor,
    :not_server_member,
    :forbidden,
    :channel_not_found
  ]

  tags ["messages"]

  operation :index,
    summary: "Buscar mensajes en un servidor",
    description:
      "Busca en los canales de texto del servidor donde el usuario tiene `VIEW_CHANNELS` " <>
        "(historia #49). `q` encuentra los mensajes que contienen ese texto, aunque sea " <>
        "parte de una palabra y sin distinguir mayúsculas; `author_id` se queda con los de " <>
        "ese autor. Tiene que venir al menos uno de los dos, y si vienen ambos se combinan. " <>
        "Los resultados van del más nuevo al más viejo y no incluyen mensajes eliminados. " <>
        "Sin coincidencias responde 200 con `messages` vacío.",
    parameters: [
      server_id: [in: :path, type: :string, required: true, description: "UUID del servidor"],
      q: [
        in: :query,
        type: :string,
        required: false,
        description: "Texto a buscar (se recorta; hasta 100 caracteres)"
      ],
      author_id: [
        in: :query,
        type: :string,
        required: false,
        description: "Id del autor de los mensajes"
      ],
      channel_id: [
        in: :query,
        type: :string,
        required: false,
        description: "Buscar solo en este canal del servidor"
      ],
      limit: [
        in: :query,
        type: :integer,
        required: false,
        description: "Tamaño de página (default 25, máx 50)"
      ],
      before: [
        in: :query,
        type: :string,
        required: false,
        description: "Id devuelto como next_cursor, para traer las coincidencias más viejas"
      ]
    ],
    responses: [
      ok: {"Coincidencias de la búsqueda", "application/json", Schemas.MessageSearchResult},
      bad_request:
        {"Búsqueda inválida (`INVALID_SEARCH_QUERY`) o cursor inválido (`INVALID_CURSOR`)",
         "application/json", Schemas.ErrorResponse},
      unauthorized:
        {"Falta o es inválido el Authorization: Bearer <jwt>", "application/json",
         Schemas.ErrorResponse},
      forbidden:
        {"No es miembro del servidor (`NOT_SERVER_MEMBER`) o no puede ver el `channel_id` pedido",
         "application/json", Schemas.ErrorResponse},
      not_found:
        {"El `channel_id` no es un canal de texto de este servidor", "application/json",
         Schemas.ErrorResponse},
      service_unavailable:
        {"No se pudo completar la búsqueda (`SEARCH_UNAVAILABLE`)", "application/json",
         Schemas.ErrorResponse}
    ]

  def index(conn, %{"server_id" => server_id} = params) do
    search = %{
      server_id: server_id,
      user_id: conn.assigns.user_id,
      text: Map.get(params, "q"),
      author_id: Map.get(params, "author_id"),
      channel_id: Map.get(params, "channel_id"),
      before: Map.get(params, "before"),
      limit: params |> Map.get("limit") |> parse_limit()
    }

    case Chat.search_messages(search) do
      {:ok, page} -> json(conn, render_page(page))
      {:error, reason} -> respond_error(conn, reason)
    end
  end

  defp render_page(%{messages: messages, next_cursor: next_cursor, total: total}) do
    %{
      "messages" => Enum.map(messages, &Message.to_api/1),
      "next_cursor" => next_cursor,
      "total" => total && total.count,
      "total_capped" => total && total.capped
    }
  end

  defp respond_error(conn, reason) when reason in @known_errors,
    do: conn |> put_status(ApiError.http_status(reason)) |> json(ApiError.payload(reason))

  defp respond_error(conn, _reason),
    do: conn |> put_status(503) |> json(ApiError.payload(:search_unavailable))

  defp parse_limit(nil), do: nil

  defp parse_limit(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, _rest} -> n
      :error -> nil
    end
  end

  defp parse_limit(_other), do: nil
end
