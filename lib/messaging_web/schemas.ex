defmodule MessagingWeb.Schemas do
  alias OpenApiSpex.Schema

  defmodule Message do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Message",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        channel_id: %Schema{type: :string, format: :uuid},
        server_id: %Schema{type: :string, format: :uuid},
        user_id: %Schema{type: :string},
        content: %Schema{type: :string},
        inserted_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "ISO 8601, UTC, always with a trailing Z"
        }
      },
      required: [:id, :channel_id, :server_id, :user_id, :content, :inserted_at]
    })
  end

  defmodule MessageList do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MessageList",
      type: :object,
      properties: %{
        messages: %Schema{type: :array, items: Message},
        next_cursor: %Schema{
          type: :string,
          nullable: true,
          description: "Message id to pass as `before` for the next page."
        }
      },
      required: [:messages, :next_cursor]
    })
  end

  defmodule ErrorResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ErrorResponse",
      type: :object,
      properties: %{
        error: %Schema{
          type: :object,
          properties: %{
            code: %Schema{type: :string},
            message: %Schema{type: :string},
            details: %Schema{type: :object}
          },
          required: [:code, :message, :details]
        }
      },
      required: [:error]
    })
  end

  defmodule SocketTicket do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SocketTicket",
      type: :object,
      properties: %{
        ticket: %Schema{
          type: :string,
          description:
            "Ticket de un solo uso. Se manda como `?ticket=<ticket>` al conectar el WebSocket."
        },
        expires_in: %Schema{
          type: :integer,
          description: "Segundos que el ticket es válido desde que se emite."
        }
      },
      required: [:ticket, :expires_in]
    })
  end
end
