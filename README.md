# messaging (Elixir)

Servicio de **mensajería** de Discordia: mensajes de texto en canales, con
entrega en tiempo real. Cubre las historias **"Enviar mensaje en un canal"**
(CA1 envío exitoso, CA2 mensaje vacío, CA3 sin permisos, CA4 mensaje muy
largo) e **"Historial y reconexión"** (CA1 carga paginada, CA2 reconexión sin
pérdida, CA3 orden cronológico).

## Stack
- Lenguaje: Elixir / Phoenix (Channels para WS, controllers para REST)
- BDD: MongoDB (`mongodb_driver`)
- Event bus: RabbitMQ (`amqp`) -- tanto para consumir eventos de dominio de
  `discordia.events` como para la propagación entre instancias (ver ADR más abajo)
- Auth: Kong valida el JWT; `messaging` confía y solo lee el claim `sub` del
  payload (sin verificar la firma, igual que `servers`)
- HTTP client: `req` (llamada a `servers` para el chequeo de permisos)
- OpenAPI: `open_api_spex`, generado automáticamente desde las anotaciones
  `operation` de los controllers

## Arquitectura y decisiones

- **Chequeo de canal (existencia + tipo `text`)**: caché local en Mongo
  (colección `channels`), poblada consumiendo `servers.channel_created` /
  `servers.channel_deleted` (`Messaging.Events.ChannelLifecycleConsumer`).
- **Chequeo de permisos (`SEND_MESSAGES`)**: llamada HTTP síncrona a
  `servers` (`Messaging.Chat.PermissionsClient`) en el momento de unirse al
  canal y en cada envío -- no se cachea porque un rol puede revocarse en
  cualquier momento.
- **Propagación entre instancias**: RabbitMQ, exchange fanout propio
  `messaging.broadcast` (`Messaging.Events.BroadcastPublisher`/
  `BroadcastConsumer`), separado de `discordia.events`. Ver
  [`docs/adr/0001-messaging-realtime-propagation.md`](https://github.com/discordia-grupo01/docs/blob/main/adr/0001-messaging-realtime-propagation.md)
  para la justificación completa (por qué RabbitMQ y no Redis Pub/Sub ni
  Phoenix.PubSub+libcluster).

## Eventos que consume
- `servers.channel_created` -- upsert en la caché local de canales.
- `servers.channel_deleted` -- evicción de la caché local de canales.

Ambos definidos en
[`events-contract`](https://github.com/discordia-grupo01/events-contract)
(`channels/events.go` + `channels/events.ex`) y documentados en
[`docs/asyncapi/channels.yaml`](https://github.com/discordia-grupo01/docs/blob/main/asyncapi/channels.yaml).

## Eventos que publica
Ninguno en `discordia.events` -- la propagación de mensajes enviados es un
detalle interno de escalado (`messaging.broadcast`, ver ADR), no un evento de
dominio para otros servicios.

## Endpoints / Channels
- WS `/socket`, channel `"channel:" <> channel_id` (`MessagingWeb.RoomChannel`):
  - `join` con `{"last_message_id": "<id>"}` opcional -- valida canal y que el
    usuario tenga `VIEW_CHANNELS`. Si viene `last_message_id`, empuja
    `"missed_messages"` con lo enviado después de ese mensaje (ver
    [Historial y reconexión](#historial-y-reconexión)).
  - `handle_in("new_message", %{"content" => "..."})` -- requiere
    `SEND_MESSAGES` en cada envío (CA1-CA4 de "Enviar mensaje").
- `GET /v1/channels/:channel_id/messages?limit=&before=<id>&after=<id>` --
  historial paginado por cursor, cada página en orden cronológico. Requiere
  `VIEW_CHANNELS`.
- `GET /livez`, `GET /readyz` (`readyz` pinguea Mongo).

Formato de error (REST y WS) siempre `{ "error": { "code", "message", "details" } }`.
Auth REST: `Authorization: Bearer <jwt>`, validado por Kong; `messaging` toma
el `user_id` del claim `sub`.

Auth del socket: el WebSocket API del browser no permite headers custom en el
handshake, y poner el JWT en la URL lo deja en logs. Por eso:
1. `POST /v1/socket-tickets` (con el Bearer normal) devuelve
   `{ "ticket": "...", "expires_in": 30 }`.
2. El cliente conecta a `/socket/websocket?ticket=<ticket>&vsn=2.0.0`.

El ticket es de un solo uso, vive 30 segundos y se guarda hasheado en Mongo
(colección `socket_tickets`, con índice TTL), así que funciona aunque el
ticket lo emita una instancia y lo consuma otra. El JWT ya no viaja en la URL.

`messaging` no verifica la firma del JWT: confía en que Kong lo validó. Por eso
no debe quedar expuesto directo a internet (solo detrás del gateway).

## Historial y reconexión

**Historial (REST).** `GET /v1/channels/:id/messages?limit=50` devuelve los
mensajes más recientes **de más viejo a más nuevo** (`limit` máx. 100). Si hay
más, `next_cursor` trae el id del mensaje más viejo de la página; se pide la
página anterior con `?before=<next_cursor>` hasta que `next_cursor` sea `null`.
`?after=<id>` hace lo inverso: devuelve lo posterior a ese mensaje, también en
orden cronológico. `before` y `after` no se pueden combinar y el cursor tiene
que ser un mensaje de ese mismo canal (si no, `400 INVALID_CURSOR`).

**Orden.** Se ordena por `(inserted_at, _id)`. Mongo guarda fechas con
milisegundos, así que dos mensajes del mismo milisegundo se desempatan por
`_id`; los ids de mensaje son UUID v7 (`Messaging.UUID.generate_v7/0`),
monótonos dentro de una instancia, así el desempate respeta el orden de envío.
El índice `messages_channel_inserted_at_id` lo crea `Messaging.Chat.IndexSetup`
al arrancar (reintenta hasta que Mongo responda).

**Reconexión.** El broker de tiempo real no guarda nada para quien está
desconectado, así que el cliente se pone al día pidiendo lo que falta:
1. Se guarda el `id` del último mensaje que recibió (en vivo o por historial).
2. Al reconectar pide un ticket nuevo (son de un solo uso) y conecta de nuevo.
3. Hace `join` con `{"last_message_id": "<id>"}`. El servidor empuja
   `"missed_messages"` con `{"messages": [...], "next_cursor": ...}`, en orden
   cronológico, hasta 100 por lote. Siempre se empuja, aun vacío, para que el
   cliente sepa que terminó de ponerse al día.
4. Si `next_cursor` no es `null` había más de un lote: sigue con
   `GET .../messages?after=<next_cursor>` hasta vaciar.

Garantías y casos borde:
- La puesta al día corre **después** de suscribirse al canal, así que no hay
  hueco entre lo recuperado y lo que llega en vivo. A cambio, un mensaje puede
  llegar dos veces (en vivo y en `missed_messages`): el cliente deduplica por `id`.
- Si el `last_message_id` no existe o es de otro canal, el servidor empuja
  `"resync_required"` y el cliente recarga el historial por REST. Si no es un
  string, el `join` falla con `INVALID_CURSOR`.
- Si falla la consulta a Mongo durante la puesta al día, el canal se cierra con
  error y el cliente de Phoenix reintenta el `join` solo.
- Un cliente que nunca recibió un mensaje no tiene `last_message_id`: al
  reconectar recarga el historial por REST.
- Al abrir un canal conviene hacer primero el `join` (y bufferear lo que llegue
  en vivo) y después pedir el historial, deduplicando por `id`, para no perder
  lo enviado entre ambos pasos.

## Mongo con TLS (Atlas)
Si `MONGO_URL` pide TLS (`?ssl=true`, `?tls=true` o `mongodb+srv://`),
`Messaging.MongoOptions` arma el driver con `verify: :verify_peer`, los
certificados raíz del sistema y verificación de hostname. Sin eso, OTP 26
rechaza la conexión (`cacerts: :undefined`). La imagen de Docker instala
`ca-certificates` por esa razón. Con una URL sin TLS (Mongo local) no se agrega nada.

## Setup local

Este repo es autocontenido: su propio `docker-compose.yml` trae Mongo y
RabbitMQ (a diferencia de `servers`/`identify-service`, que asumen un
RabbitMQ compartido externo). Dos formas de levantarlo:

**Todo en Docker** (más simple, sin instalar Elixir/Erlang):
```bash
cp .env.example .env
docker compose up --build
```

**`mix phx.server` en el host** (mejor para desarrollar, con recarga en caliente):
```bash
cp .env.example .env
asdf install   # fija erlang 26.2.1 / elixir 1.16.2-otp-26, ver .tool-versions
mix local.hex --force && mix local.rebar --force
mix deps.get
docker compose up -d mongo rabbitmq
mix phx.server
```

En ambos casos, `SERVERS_BASE_URL` (`.env`) tiene que apuntar a una instancia
de `servers` corriendo (para el chequeo de permisos) -- por default asume
`http://localhost:8080`. Si `servers` corre en su propio `docker compose`
aparte (no en el mismo proyecto que este) y acá levantaste todo con **"Todo
en Docker"**, `localhost` desde adentro del container `api` no llega al host
-- usá `SERVERS_BASE_URL=http://host.docker.internal:8080` en ese caso (Mac/
Windows con Docker Desktop). Si corrés `mix phx.server` en el host, `localhost`
funciona normal.

## Tests
```bash
make test   # mix coveralls -- falla si la cobertura total < 70% (coveralls.json)
```
Los tests unitarios y el e2e de `RoomChannel` usan `Mox`
(`Messaging.Chat.RepoMock`, `Messaging.Chat.PermissionsClientMock`) y
`Messaging.Events.LocalBroadcaster` (entrega en tiempo real in-process, sin
broker) -- no necesitan Mongo ni RabbitMQ reales.

Algunos tests de integración sí necesitan infraestructura real y se saltan solos
si no está (mismo patrón que `servers`/`identify-service` con
`DATABASE_HOST`):
```bash
docker compose up -d mongo   # en este repo
# + RabbitMQ del repo rabbit-mq
export MONGO_URL=mongodb://localhost:27017/messaging_test
export RABBITMQ_URL=amqp://guest:guest@localhost:5672/
mix test
```
- `test/messaging/events/channel_lifecycle_consumer_test.exs`: publica un
  evento real y confirma que la caché de canales en Mongo se actualiza.
- `test/messaging/chat/repo/mongo_test.exs`: paginación hacia atrás y hacia
  adelante contra Mongo real, con mensajes del mismo milisegundo y el índice.
- `test/messaging/events/broadcast_test.exs`: el camino real
  `BroadcastPublisher` -> RabbitMQ -> `BroadcastConsumer` -> PubSub local.

## OpenAPI
```bash
make openapi   # regenera openapi.yaml desde las anotaciones `operation`
```
El CI lo regenera y commitea solo si cambió (mismo patrón que `servers`/`identify-service`).

## Carga (k6)
```bash
docker compose up -d mongo   # + RabbitMQ, + mix phx.server
k6 run load/send_message.js
```
Resultados documentados en [`load/RESULTS.md`](load/RESULTS.md).

## Formateo automático
Este repo se autoformatea con `mix format` en cada commit. Activalo una vez por clone:
```bash
git config core.hooksPath .githooks
```
Si usan VS Code con la extension ElixirLS, tambien formatea al guardar (ya configurado en .vscode/settings.json).

El CI sigue corriendo `mix format --check-formatted` como red de seguridad, por si alguien clono sin activar el hook.

## Version de Elixir/Erlang (asdf)
Este repo fija la version exacta en `.tool-versions`, para que todo el equipo y el CI usen la misma.
```bash
brew install asdf
asdf plugin add erlang
asdf plugin add elixir
asdf install
```

## Vulnerabilidad conocida (dependencia transitiva)
`cowlib` (traído por `plug_cowboy`/`cowboy`) tiene 3 CVEs abiertos sin
versión parcheada disponible en ningún release al momento de escribir esto
(`EEF-CVE-2026-43966`, `-43969`, `-43971` -- ver `mix hex.audit`). Está
pineado a `2.19.0` (la última que compila contra el OTP 26 que fija este
repo; `2.20.0` no compila en OTP 26) en `mix.exs` con un comentario que
explica por qué. Se debe revisar `mix hex.audit` periódicamente y
actualizar apenas exista un release parcheado compatible.

## Arquitectura del proyecto

Phoenix organiza el codigo por **Context** (dominio de negocio), no por capa
tecnica como Spring Boot. No existe una carpeta `services/` ni `controllers/`
global para todo el proyecto.

```
lib/
├── messaging/                    # Logica de negocio pura, sin HTTP
│   ├── application.ex            # Arranca el supervisor de la app
│   ├── mongo_options.ex          # Opciones del driver de Mongo (TLS para Atlas)
│   ├── uuid.ex                   # UUIDv4 y UUIDv7 monótono (ids de mensajes), sin depender de Ecto
│   ├── auth/
│   │   ├── token.ex              # user_id (claim sub) del Bearer; la firma la valida Kong
│   │   ├── socket_ticket.ex      # Emite/canjea tickets de un solo uso para el WebSocket
│   │   ├── ticket_store.ex       # Behaviour de almacenamiento de tickets
│   │   └── ticket_store/mongo.ex # Implementacion real (Mongo, indice TTL)
│   ├── chat/                     # Context: mensajes y canales
│   │   ├── message.ex            # Entity: un mensaje
│   │   ├── channel_cache.ex      # Entity: read-model local de un canal
│   │   ├── repo.ex               # Behaviour de persistencia (Mongo o Mox en tests)
│   │   ├── repo/mongo.ex         # Implementacion real (mongodb_driver)
│   │   ├── index_setup.ex        # Crea el índice del historial al arrancar (con reintentos)
│   │   ├── permissions_client.ex # Behaviour de permisos (SEND_MESSAGES / VIEW_CHANNELS)
│   │   └── permissions_client/http.ex  # Implementacion real (Req -> servers)
│   ├── chat.ex                   # API publica del context (hace de "Service")
│   └── events/                   # Consumo/publicacion de eventos (discordia.events y messaging.broadcast)
│       ├── channel_event.ex
│       ├── channel_lifecycle_consumer.ex
│       ├── broadcaster.ex
│       ├── broadcast_publisher.ex
│       ├── broadcast_consumer.ex
│       ├── local_broadcaster.ex  # Broadcaster in-process (tests / single-instance)
│       └── backoff.ex
│
└── messaging_web/                # Capa web (HTTP y websockets)
    ├── endpoint.ex                # El servidor en si
    ├── router.ex                 # Mapea rutas -> controllers
    ├── api_spec.ex                # Fuente del OpenAPI generado
    ├── api_error.ex               # Envelope { "error": {...} } compartido
    ├── schemas.ex                 # Schemas OpenAPI de las respuestas
    ├── controllers/
    │   ├── health_controller.ex
    │   ├── message_controller.ex
    │   ├── socket_ticket_controller.ex
    │   └── error_json.ex
    ├── plugs/
    │   └── authenticate.ex        # Authorization: Bearer <jwt> (REST), toma el sub
    └── channels/
        ├── user_socket.ex         # Punto de entrada de websockets (ticket por params)
        └── room_channel.ex        # Channel de un canal de texto
```

### Equivalencia con Spring Boot

| Spring Boot | Phoenix | Diferencia clave |
|---|---|---|
| `@RestController` | `messaging_web/controllers/*.ex` | Igual de simple: recibe request, delega, responde |
| `@Service` | `messaging/<context>/<context>.ex` | En Spring es una clase; en Phoenix es un modulo con funciones publicas dentro de SU carpeta de dominio |
| `@Entity` | `messaging/<context>/<entidad>.ex` | Con Ecto es un `schema`; sin Ecto (Mongo) es un struct comun |
| `@Repository` / `JpaRepository` | `Repo` (behaviour propio + implementacion Mongo) | Con Mongo lo escriben ustedes, no hay auto-repository |
| Paquete por capa | Carpeta por Context | NO hay una carpeta `services/` global |

### Regla de oro

El controller/channel (capa web) **nunca** accede directo a la entidad ni a la
base de datos. Siempre entra por la API publica del Context: `Messaging.Chat.<accion>(...)`.

## CI local
```bash
make ci
```
