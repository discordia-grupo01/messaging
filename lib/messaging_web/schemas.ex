defmodule MessagingWeb.Schemas do
  alias OpenApiSpex.Schema

  defmodule Attachment do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Attachment",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        url: %Schema{
          type: :string,
          format: :uri,
          description: "URL pública del archivo en el almacenamiento (Supabase Storage)"
        },
        name: %Schema{type: :string, description: "Nombre original, ya saneado"},
        content_type: %Schema{
          type: :string,
          enum: ["image/jpeg", "image/png", "image/webp", "application/pdf"],
          description:
            "Detectado por el contenido real del archivo, no por el que declaró el cliente"
        },
        size: %Schema{type: :integer, description: "Tamaño en bytes"}
      },
      required: [:id, :url, :name, :content_type, :size]
    })
  end

  defmodule Message do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Message",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        channel_id: %Schema{type: :string, format: :uuid},
        server_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description: "null en los mensajes directos (no pertenecen a ningún servidor)"
        },
        user_id: %Schema{type: :string},
        content: %Schema{type: :string},
        inserted_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "ISO 8601, UTC, always with a trailing Z"
        },
        edited: %Schema{
          type: :boolean,
          description: "true si el autor lo editó después de enviarlo"
        },
        edited_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "Momento de la última edición (ISO 8601, UTC); null si nunca se editó"
        },
        mentions: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description:
            "Ids de los usuarios mencionados con `<@id>` que son miembros del servidor (vacío en mensajes directos)"
        },
        mention_roles: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description:
            "Ids de los roles mencionados con `<@&id>`; solo cuentan si el autor tiene MENTION_EVERYONE"
        },
        mention_everyone: %Schema{
          type: :boolean,
          description:
            "true si el mensaje mencionó `@everyone` y el autor tiene MENTION_EVERYONE; si no, queda como texto"
        },
        attachments: %Schema{
          type: :array,
          items: Attachment,
          description: "Archivos adjuntos del mensaje (vacío si no tiene)"
        },
        reactions: %Schema{
          type: :array,
          description:
            "Reacciones del mensaje, en el orden en que se usó cada emoji por primera vez. " <>
              "Viene en el historial; los eventos `new_message` y `message_updated` no la traen.",
          items: %Schema{
            type: :object,
            properties: %{
              emoji: %Schema{type: :string},
              count: %Schema{type: :integer, minimum: 1},
              reacted_by_me: %Schema{
                type: :boolean,
                description: "true si quien pide el historial es uno de los que reaccionó"
              }
            },
            required: [:emoji, :count, :reacted_by_me]
          }
        }
      },
      required: [
        :id,
        :channel_id,
        :server_id,
        :user_id,
        :content,
        :inserted_at,
        :edited,
        :mentions,
        :mention_roles,
        :mention_everyone,
        :attachments
      ]
    })
  end

  defmodule EditMessageRequest do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "EditMessageRequest",
      type: :object,
      properties: %{
        content: %Schema{
          type: :string,
          description: "Contenido nuevo (máx. 2000 caracteres, se recorta)"
        }
      },
      required: [:content]
    })
  end

  defmodule Conversation do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Conversation",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid, description: "Id de la conversación (un canal)"},
        partner_id: %Schema{type: :string, description: "El otro participante"},
        unread: %Schema{
          type: :boolean,
          description: "true si el último mensaje es del otro y todavía no lo marcaste como leído"
        },
        blocked_by_me: %Schema{
          type: :boolean,
          description: "true si bloqueaste al otro participante (nunca se informa lo contrario)"
        },
        last_message_at: %Schema{type: :string, format: :"date-time", nullable: true},
        last_message: %Schema{
          allOf: [Message],
          nullable: true,
          description: "null si el último mensaje fue eliminado"
        }
      },
      required: [:id, :partner_id, :unread, :blocked_by_me]
    })
  end

  defmodule ConversationList do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ConversationList",
      type: :object,
      properties: %{conversations: %Schema{type: :array, items: Conversation}},
      required: [:conversations]
    })
  end

  defmodule BlockRequest do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "BlockRequest",
      type: :object,
      properties: %{
        user_id: %Schema{type: :string, description: "Id del usuario a bloquear"}
      },
      required: [:user_id]
    })
  end

  defmodule BlockList do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "BlockList",
      type: :object,
      properties: %{
        blocks: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            properties: %{
              user_id: %Schema{type: :string, description: "El usuario que bloqueaste"},
              created_at: %Schema{type: :string, format: :"date-time"}
            },
            required: [:user_id, :created_at]
          }
        }
      },
      required: [:blocks]
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
          description:
            "Hay más mensajes: id para pasar como `before` (o como `after` si se pidió con `after`). null si no hay más."
        }
      },
      required: [:messages, :next_cursor]
    })
  end

  defmodule Mention do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Mention",
      description: "Una notificación destacada: un mensaje que te mencionó y todavía no leíste.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, description: "`<message_id>:<user_id>`"},
        message_id: %Schema{type: :string, format: :uuid},
        channel_id: %Schema{type: :string, format: :uuid},
        server_id: %Schema{type: :string, format: :uuid},
        author_id: %Schema{type: :string, description: "Quien te mencionó"},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        message: %Schema{
          allOf: [Message],
          nullable: true,
          description: "El mensaje; null si ya no está disponible"
        }
      },
      required: [:id, :message_id, :channel_id, :server_id, :author_id, :inserted_at, :message]
    })
  end

  defmodule MentionList do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MentionList",
      type: :object,
      properties: %{mentions: %Schema{type: :array, items: Mention}},
      required: [:mentions]
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
