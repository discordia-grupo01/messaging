# Historias de usuario

Las historias del catálogo de la cátedra que resuelve este servicio, con su número, y las que resuelve junto con otros servicios. Las rutas REST están en [`openapi.yaml`](../openapi.yaml). Los mensajes en tiempo real viajan por WebSocket (`/socket`), con un ticket de un solo uso que se pide con `POST /v1/socket-tickets`.

## Obligatorias

| # | Historia | Puntos | Cómo se usa |
|---|---|---|---|
| 15 | Enviar mensaje en un canal | 8 | WebSocket, canal `channel:<id>`, evento `new_message` |
| 16 | Historial y reconexión | 13 | `GET /v1/channels/{channelId}/messages` con `limit`, `before`, `after` o `around`. Al reconectar, `join` con `last_message_id` devuelve lo que se perdió. |

## Optativas

| # | Historia | Puntos | Cómo se usa |
|---|---|---|---|
| 37 | Estado de actividad | 5 | `GET /v1/presence`, WebSocket canal `presence:<serverId>` y eventos `set_status` y `activity` |
| 42 | Enviar mensaje directo (DM) | 8 | WebSocket, canal `user:<id>`, evento `send_dm`. `GET /v1/conversations` y `POST /v1/conversations/{id}/read` |
| 43 | Bloquear y desbloquear usuarios | 3 | `POST /v1/blocks`, `GET /v1/blocks`, `DELETE /v1/blocks/{userId}` |
| 44 | Editar mensaje | 3 | `PATCH /v1/channels/{channelId}/messages/{messageId}` o el evento `edit_message` |
| 45 | Eliminar mensaje | 3 | `DELETE /v1/channels/{channelId}/messages/{messageId}` o el evento `delete_message` |
| 46 | Menciones | 5 | `GET /v1/mentions`, `POST /v1/channels/{channelId}/mentions/read`. El usuario mencionado recibe el evento `mention`. |
| 47 | Adjuntar archivos en mensajes | 5 | `POST /v1/attachment-tickets`, `POST /v1/attachments` y `POST /v1/attachments/direct` |
| 48 | Reacciones con emoji | 3 | Eventos `add_reaction` y `remove_reaction` del canal |
| 49 | Buscar mensajes | 5 | `GET /v1/servers/{serverId}/messages/search` |

## Historias en las que participa

Estas historias las completan otros servicios. Acá está la parte que le toca a `messaging`:

| # | Historia | Qué hace este servicio |
|---|---|---|
| 29, 30 | Suspender y reactivar usuario | Recibe el evento firmado de `admin` y bloquea o habilita lo que puede hacer el usuario. |
| 50 | Iniciar y recibir llamada de voz privada | Comprueba que los dos usuarios estén en la conversación y que no haya un bloqueo: `GET /v1/voice-access/{recipientId}`. |
| 60 | Silenciar temporalmente a un miembro | Rechaza los mensajes de un miembro silenciado por `servers`. |
| 63 | Filtro automático de palabras prohibidas | Aplica la lista que guarda `servers` al enviar un mensaje. |
| 69 | Suspender servidor completo | Recibe el evento firmado de `admin` y bloquea el servidor. |
| 75 | Gestionar emojis personalizados del servidor | Guarda los emojis que publica `servers` y los lista: `GET /v1/custom-emojis`. |
| 76 | Suscribirse a Plan Premium | Recibe el estado de Premium (evento firmado de `billing`) y habilita los adjuntos grandes. |
| 80 | Ver beneficios de servidor boosteado | Guarda el nivel de boost del servidor y ajusta los límites. |

## Decisiones técnicas

- **ADR 0001, propagación en tiempo real:** cómo un mensaje llega a los usuarios de todas las instancias.
- **ADR 0002, tickets de WebSocket:** por qué el JWT no viaja en la URL del socket.
- **ADR 0003, réplica local de permisos:** por qué `messaging` guarda su propia copia de roles, permisos y usuarios.
- **ADR 0004, outbox en PostgreSQL:** por qué el evento se anota antes de guardar el mensaje.
- **ADR 0006, más de una instancia:** qué se comparte entre instancias y qué no.
