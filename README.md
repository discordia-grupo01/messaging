# messaging (Elixir)

## Autorización de llamadas privadas

Messaging expone internamente `GET /v1/voice-access/:recipient_id?conversation_id=...`
para que signaling valide que ambos usuarios pertenecen a la conversación
directa y que no existe un bloqueo en ninguno de los dos sentidos. La ruta
requiere el JWT del usuario llamante y no crea ni modifica datos.

Servicio de **mensajería** de Discordia: mensajes de texto en canales, con
entrega en tiempo real. Cubre las historias **"Enviar mensaje en un canal"**
(CA1 envío exitoso, CA2 mensaje vacío, CA3 sin permisos, CA4 mensaje muy
largo) e **"Historial y reconexión"** (CA1 carga paginada, CA2 reconexión sin
pérdida, CA3 orden cronológico). También cubre la parte de mensajería de
**"Menciones"** (#46) y el **"Estado de actividad"** (#37).

## Stack
- Lenguaje: Elixir / Phoenix (Channels para WS, controllers para REST)
- BDD: MongoDB (`mongodb_driver`) para mensajes, conversaciones, bloqueos, menciones, estado de
  actividad y la réplica local; **Postgres** (`postgrex`, Supabase en producción) solo para el outbox
- Event bus: RabbitMQ (`amqp`) -- tanto para consumir eventos de dominio de
  `discordia.events` como para la propagación entre instancias (ver ADR más abajo)
- Auth: Kong valida el JWT; `messaging` confía y solo lee el claim `sub` del
  payload (sin verificar la firma, igual que `servers`)
- HTTP client: `req` (solo para subir y borrar archivos en Cloudinary)
- OpenAPI: `open_api_spex`, generado automáticamente desde las anotaciones
  `operation` de los controllers

## Arquitectura y decisiones

- **Chequeo de canal (existencia + tipo `text`)**: caché local en Mongo
  (colección `channels`), poblada consumiendo `servers.channel_created` /
  `servers.channel_deleted` (`Messaging.Events.ChannelLifecycleConsumer`). Se
  guardan también los canales de voz: así escribir en uno responde
  `CHANNEL_NOT_TEXT` en vez de un engañoso "el canal no existe".
- **Chequeo de permisos (`VIEW_CHANNELS` / `SEND_MESSAGES` / `MANAGE_MESSAGES`)**:
  **local, sin llamar a `servers`** (ADR 0003). `Messaging.Chat.PermissionsStore.Replica`
  lee de Mongo el dueño del servidor, los permisos de cada rol, los roles del miembro y los
  overrides del canal, y `Messaging.Chat.Permissions` calcula los permisos **efectivos en el
  canal** con la misma regla que `servers` (#57): el dueño y los administradores pueden todo;
  el resto parte de la unión de sus roles y aplica el override de `@everyone` y después los de
  sus otros roles (`allow` gana a `deny`). Un rol al que le denegaron `VIEW_CHANNELS` en
  `#staff` no puede abrirlo ni leer su historial, aunque lo tenga a nivel servidor. Quien no
  figura como miembro, o un rol que todavía no llegó, cuenta como "sin permiso". Se decide en
  el `join`, en cada envío y al editar o borrar.
- **Menciones**: `Messaging.Chat.MentionResolver.Replica` decide, con la misma réplica,
  cuáles valen y a quién notificar: un usuario mencionado cuenta si es miembro; los roles y
  `@everyone` solo si quien escribe tiene `MENTION_EVERYONE` (el dueño y los administradores
  lo tienen implícito); se avisa a quienes **ven ese canal**, ya con los overrides. Los
  mensajes sin menciones no hacen nada de esto.
- **Existencia de un usuario** (primer DM y bloqueos): colección `replica_users`
  (`user_id` + `version`), alimentada por `users.profile_updated`. Un usuario recién
  registrado no existe para `messaging` hasta que llega su evento (unos segundos).
- **Propagación entre instancias**: RabbitMQ, exchange fanout propio
  `messaging.broadcast` (`Messaging.Events.BroadcastPublisher`/
  `BroadcastConsumer`), separado de `discordia.events`. Cada instancia tiene su propia cola
  **durable** (`messaging.broadcast.<id>`) que vence a los 10 minutos sin consumidor y
  descarta mensajes de más de 5, así que si RabbitMQ se reinicia o la instancia se
  reconecta tarde, lo publicado mientras tanto la espera. Todo lo que se publica sale del
  outbox (ver "Outbox").

## Eventos que consume
- `servers.channel_created` -- upsert en la caché local de canales. Se descarta si
  llega después de borrarse ese canal o su servidor.
- `servers.channel_deleted` -- evicción de la caché local de canales y **cierre de
  los sockets** unidos a ese canal.
- `servers.server_deleted` -- se eliminó el servidor: se borran **todos los
  mensajes** de sus canales y los canales de la caché. El evento trae los ids de
  los canales (`channel_ids`) y además se usan los que la caché conoce de ese
  servidor, así que no depende de que la caché esté completa. Es idempotente:
  si se entrega dos veces, la segunda no encuentra nada que borrar. Un
  `channel_ids` que no sea una lista de strings se descarta
  (`discarded_invalid_payload` en `consumed_events`) sin tocar nada. También
  **cierra los sockets** de todos sus canales.
- `servers.member_left` -- alguien dejó de ser miembro de un servidor (se fue,
  lo expulsaron o lo banearon): se borran sus menciones de ese servidor, porque
  `GET /v1/mentions` trae el mensaje y si no seguiría leyendo contenido de un
  servidor que ya no ve, y se le **cierran los sockets** de los canales de ese
  servidor. Mismo consumer y misma cola que los anteriores.
- `servers.member_joined` -- solo se registra, para poder ordenar contra un
  `member_left` (ver más abajo). No se publica nada a los clientes.
- `servers.channel_access_revoked` -- uno o más miembros dejaron de ver un canal
  (`VIEW_CHANNELS` ya con overrides) por un cambio de permisos: overrides, roles
  editados, borrados, asignados o quitados, transferencia de propiedad, kick,
  ban o salida. Trae `channel_id` y los `user_ids` que **perdieron** el acceso
  (nunca vacío); a cada uno se le **cierra el socket** de ese canal con
  `reason: "permissions_changed"`. No pasa por `event_clocks`: solo corta
  conexiones y el `join` vuelve a chequear los permisos actuales, así que un
  duplicado o uno fuera de orden cuesta a lo sumo una reconexión.
- `servers.word_filter_updated` -- la lista completa de palabras prohibidas de
  un servidor (ver [Palabras prohibidas](#palabras-prohibidas)). Se guarda en
  `replica_word_filters` y, como las fotos de permisos, gana la de
  `occurred_at` más nuevo.

### Réplica local de permisos y usuarios

Todos van por la misma cola (`messaging.channel_lifecycle`) y son **fotos completas** de una
entidad, no diferencias. Cada una se guarda solo si su `occurred_at` es mayor o igual al de la
que ya hay (`users.profile_updated` usa `version`); si no, se descarta como `ignored_stale`.
Detalle del contrato en `docs/asyncapi/permissions.yaml`.

| Evento | Qué hace |
|---|---|
| `servers.owner_updated` | guarda el dueño del servidor (`replica_servers`) |
| `servers.role_updated` | guarda los permisos del rol y si es `@everyone` (`replica_roles`) |
| `servers.role_deleted` | deja una lápida (TTL 7 días) y saca el rol de los miembros y de los overrides |
| `servers.member_roles_updated` | reemplaza los roles del miembro (`replica_members`) |
| `servers.channel_overrides_updated` | reemplaza todos los overrides del canal (`replica_overrides`); lista vacía = ninguno |
| `users.profile_updated` | guarda `user_id` y `version` (`replica_users`) |

Además, `servers.member_left` quita al miembro de la réplica, `servers.channel_deleted` borra
los overrides del canal y `servers.server_deleted` borra todo lo replicado de ese servidor.
Los eventos de un servidor ya borrado se ignoran.

**Alta y recuperación.** RabbitMQ no guarda lo publicado antes de que exista la cola, así que
al sumar este consumidor hay que desplegar `messaging` primero (declara las claves de ruteo) y
después `servers` (migración `0022_backfill_access_events`) e `identify-service`
(`000016_republish_profile_events`), que re-publican todo. Se puede repetir sin riesgo.

`servers` publica `member_left` en **todas** las salidas (irse, kick, ban y
borrado del servidor), así que ese único evento cubre los cuatro casos.
`member_banned` y `member_kicked` existen en el contrato pero `messaging` no los
necesita.

### Orden de los eventos
Los eventos pueden llegar duplicados o fuera de orden. Se resuelve como en
`identify-service`: **last-write-wins por `occurred_at`**. Por cada cosa
(un canal, un servidor, o un par miembro–servidor) se guarda en `event_clocks`
el estado y el instante del último evento aplicado, y un evento solo se aplica
si es igual o más nuevo (la comparación es atómica en Mongo, así que dos
instancias o dos eventos simultáneos no se pisan). Uno que llega tarde se
descarta **sin error** y se anota en `consumed_events` como `ignored_stale`.
- Un `member_left` anterior a un `member_joined` posterior no expulsa a nadie.
- Un `channel_created` posterior a su `channel_deleted`, o a que se borró su
  servidor, no resucita el canal.
- Los borrados dejan una marca que **vence a los 7 días** (índice TTL); las de
  miembros no vencen.
- Un `occurred_at` que no es una fecha válida invalida todo el evento.

### Si el procesamiento falla
Un fallo de infraestructura (Mongo, RabbitMQ) al aplicar un evento no lo pierde:
se registra como `error` (`channel_lifecycle_event_failed`), se espera un
segundo y se **devuelve a la cola** para reintentarlo. Un evento mal formado,
en cambio, se descarta (reintentarlo no lo arreglaría).

### Cierre de conexiones
Cuando alguien pierde el acceso a un canal ya no solo se le rechazan las
acciones nuevas: se le **cierra el socket**. El consumer publica
`access_revoked` por el fanout de RabbitMQ (`messaging.broadcast`) a cada
`channel:<id>` afectado, así llega a las conexiones de **todas las instancias**.
Cada canal abierto lo intercepta: si va para su usuario (o para todos, en un
borrado), le empuja al cliente

```json
{"channel_id": "…", "reason": "member_left" | "permissions_changed" | "channel_deleted" | "server_deleted"}
```

y se cierra (`phx_close`, sin reconexión automática del cliente de Phoenix). Si
el cliente intenta volver a unirse, el `join` consulta permisos y lo rechaza.
Los DM no se tocan: no dependen de ningún servidor.

Cuando un usuario deja de ser miembro (se fue, lo echaron o se borró el
servidor), además se le avisa en su sala personal `user:<id>`, que tiene
abierta aunque no esté mirando ese servidor:

```json
{"server_id": "…"}
```

con el evento `server_left`. El cliente lo usa para sacar el servidor de su
lista y, si lo tenía abierto, volver al inicio.

Definidos en
[`events-contract`](https://github.com/discordia-grupo01/events-contract)
(`channels/events.go` + `channels/events.ex`, `servers/events.go` +
`servers/events.ex` y `membership/events.go` + `membership/events.ex`) y
documentados en
[`docs/asyncapi/channels.yaml`](https://github.com/discordia-grupo01/docs/blob/main/asyncapi/channels.yaml).

## Usuarios suspendidos
Cuando el staff suspende una cuenta, `discordia-admin` publica `admin.user_suspended` (y
`admin.user_reactivated` al levantarla). Como en Discord, **un suspendido no puede hacer nada**
en mensajería: ni enviar, editar ni borrar mensajes, ni reaccionar, ni adjuntar archivos, ni
mandar DM, ni leer su historial, ni pedir tickets de socket ni abrir o mantener sockets. Sus
mensajes anteriores siguen visibles para los demás.

- **Consumidor.** `Messaging.Events.AdminEventsConsumer` lee la cola durable
  `messaging.admin_events` (ack manual, una sola instancia recibe cada evento). Verifica la firma
  `HMAC-SHA256(ADMIN_EVENTS_HMAC_SECRET, texto)` en hexadecimal minúsculas, donde el texto son
  `routing_key`, `event_id`, `user_id`, `version` y `occurred_at` unidos por saltos de línea, con
  `occurred_at` tal cual llegó (admin lo firma en UTC). Sin firma o con firma
  inválida (o de otra routing key) el evento **no cambia nada**: se descarta sin reencolar, se
  loguea `admin_events_consumer_invalid_signature` y queda en `consumed_events` como
  `discarded_invalid_signature`.
- **Estado.** Colección Mongo `suspended_users`: `{_id: user_id, suspended, version, updated_at}`.
  Un evento se aplica solo si su `version` es mayor a la guardada, así que los duplicados, los
  reordenados y los viejos no cambian nada (`ignored_stale`). Vive en Mongo, no en memoria:
  reiniciar no pierde las suspensiones. `Messaging.Suspension.suspended?/1` lo lee con una caché
  ETS de 5 s que se invalida al aplicar un evento.
- **Rechazo en capas.** El plug `Authenticate` responde `403 ACCOUNT_SUSPENDED` en toda la API
  REST; `UserSocket.connect` rechaza el ticket (aunque se haya emitido antes de la suspensión);
  `join` y `handle_in` de `RoomChannel` y `UserChannel` responden el mismo error; y las
  escrituras de `Messaging.Chat` lo verifican, así que el bloqueo vale por cualquier camino.
- **Corte de sockets abiertos.** Al suspender, el consumidor publica `disconnect` por el
  fanout `messaging.broadcast` al topic `user_socket:<user_id>` (el `id/1` de `UserSocket`) y cada
  instancia hace el `Endpoint.broadcast!` local: Phoenix cierra los sockets de ese usuario
  (`1001`), en **todas** las instancias. Si el aviso se perdiera, la siguiente acción igual
  queda frenada por los chequeos de arriba.
- **Si no se puede leer el estado** (Mongo caído) no se deja pasar a nadie: la API responde
  `503 SUSPENSION_UNAVAILABLE`, el socket se rechaza y `Chat` devuelve el mismo error.
- **Reactivar** (evento con `version` mayor) devuelve todas las capacidades.
- **Arranque.** `ADMIN_EVENTS_HMAC_SECRET` tiene que ser el mismo valor que en admin. Si está
  vacía, el consumidor **no arranca** y se loguea `admin_events_consumer_not_started`: nunca se
  aceptan eventos que no se pueden verificar. Si `messaging` se despliega con la cola vacía y ya
  había suspendidos, hay que correr `make republish-suspensions` en `discordia-admin` una vez.

| Variable | Qué es |
|---|---|
| `ADMIN_EVENTS_HMAC_SECRET` | Secreto compartido con `discordia-admin` para verificar la firma de los eventos `admin.*` |

## Servidores suspendidos (HU #69)
Cuando el staff suspende un servidor, `discordia-admin` publica `admin.server_suspended` (y
`admin.server_reactivated` al levantarlo). Mientras dure, **nadie** puede leer ni escribir en
ninguno de sus canales, el owner incluido: ni historial, ni enviar, editar o borrar mensajes, ni
reaccionar, ni adjuntar archivos, ni buscar, ni unirse a un canal. Los **mensajes no se borran**:
al reactivar todo vuelve. Los DM no se ven afectados.

- **Consumidor.** Es el mismo `AdminEventsConsumer` y la misma cola `messaging.admin_events`, con
  dos bindings más. La firma es la de los eventos de usuario con `server_id` como sujeto
  (`routing_key`, `event_id`, `server_id`, `version`, `occurred_at`, unidos por saltos de línea;
  se prueba con los vectores de `events-contract` v0.13.1). Firma ausente o inválida, JSON roto,
  `server_id` vacío o `version < 1` se descartan sin reencolar y sin cambiar nada. Una falla de
  Mongo reencola.
- **No consume `admin.server_deletion_requested`**: `servers` hace el borrado y messaging reacciona
  al `servers.server_deleted` que publica, como siempre.
- **Estado.** Colección Mongo `suspended_servers`: `{_id: server_id, suspended, version,
  updated_at}`, con la misma regla de versión que los usuarios. Un servidor sin documento está
  activo. `Messaging.ServerSuspension` lo lee con una caché ETS de 5 s (se invalida al aplicar un
  evento en esa instancia; las otras se enteran dentro de la ventana).
- **Rechazo.** Todas las operaciones sobre un canal resuelven el canal en `Chat.fetch_channel/1`,
  y ahí se frena: responde `403 SERVER_SUSPENDED` en REST (historial, edición, borrado, adjuntos,
  menciones y búsqueda) y en el `join` y los `handle_in` de `RoomChannel`. Un canal de un servidor
  suspendido se trata como oculto en `GET /v1/messages`. Si no se puede leer el estado, falla
  cerrado con `503 SUSPENSION_UNAVAILABLE`. Una cuenta suspendida recibe antes
  `ACCOUNT_SUSPENDED`.
- **Corte de sockets.** Al suspender se cierran, en todas las instancias, los sockets de todos los
  canales del servidor (`Sockets.close_channels/2`, motivo `server_suspended`, el mismo mecanismo
  que `server_deleted`). Si el aviso se pierde, el siguiente mensaje o join igual se rechaza.
  Reactivar no corta nada.
- **Aviso a cada miembro.** Al aplicar una suspensión o una reactivación se publica
  `server_suspended` o `server_reactivated` (`{"server_id": "…"}`) en la sala `user:<id>` de cada
  miembro de la réplica (`Repo.list_members/1`), así el cliente marca el servidor como suspendido
  (o lo recupera) aunque no tenga ningún canal abierto. Un evento viejo no avisa a nadie. Si no se
  pueden listar los miembros se registra y el evento se confirma igual: `GET /v1/servers` de
  `servers` informa `suspended` en la próxima carga.
- **Pendiente de decidir:** el topic de presencia `presence:<server_id>` y el listado de menciones
  sin leer no distinguen servidores suspendidos (los clientes ocultan esas menciones).
- **Despliegue.** Desplegar `messaging` antes que `admin`; las suspensiones que ya existían se
  re-publican con `make republish-suspensions` en `discordia-admin`.

## Premium (`billing.premium_updated`)
`discordia-billing` decide quién es Premium y publica el estado completo de cada usuario en
`billing.premium_updated`.

- **Consumidor.** `Messaging.Events.BillingEventsConsumer` lee la cola durable
  `messaging.billing_events` (ack manual) y verifica la firma HMAC-SHA256 definida en
  `events-contract/billing`. Con firma inválida el evento **no cambia nada**: se descarta sin
  reencolar y queda en `consumed_events` como `discarded_invalid_signature`.
- **Estado.** Colección Mongo `premium_users`: `{_id: user_id, active, version, updated_at}`. Un
  evento se aplica solo si su `version` es mayor a la guardada. Un usuario sin documento no es
  Premium. `Messaging.Premium.premium?/1` lo lee.
- **Arranque.** `BILLING_EVENTS_HMAC_SECRET` tiene que ser el mismo valor que en billing. Si está
  vacía, el consumidor **no arranca**, la cola no se crea y se loguea
  `billing_events_consumer_not_started`. Los eventos publicados antes de que exista la cola se
  pierden, así que al desplegarlo por primera vez hay que republicarlos desde billing.

| Variable | Qué es |
|---|---|
| `BILLING_EVENTS_HMAC_SECRET` | Secreto compartido con `discordia-billing` para verificar la firma de `billing.premium_updated` |

## Eventos que publica
En `discordia.events` (exchange `topic`, por el outbox, en la misma transacción que el mensaje):

| Routing key | Cuándo | Payload |
|---|---|---|
| `messaging.message_created` | Se crea un mensaje en un canal de un servidor | `occurred_at`, `server_id`, `channel_id`, `message_id`, `author_id`, `mentioned_user_ids` (ya resueltos y validados, sin el autor), `channel_name` y `content_preview` (opcionales) |
| `messaging.direct_message_created` | Se crea un mensaje directo | `occurred_at`, `conversation_id`, `message_id`, `author_id`, `recipient_id`, `content_preview` (opcional) |
| `messaging.message_updated` | Se edita el texto de un mensaje de un canal de un servidor (solo si cambió; los directos no lo publican) | `occurred_at` (el momento de la edición), `server_id`, `channel_id`, `message_id`, `author_id`, `mentioned_user_ids` (las menciones **después** de editar), `channel_name` y `content_preview` (opcionales) |
| `messaging.message_deleted` | Se borra un mensaje, de un canal o directo | `occurred_at` (el momento del borrado), `server_id` (no viaja en un directo), `channel_id` (la conversación en un directo), `message_id`, `author_id`; nunca el texto |
| `messaging.user_presence_changed` | Cambia lo que importa para el push de un usuario (ver abajo) | `occurred_at`, `user_id`, `connections` (`active`, `idle` o `none`), `do_not_disturb`, `version` |

**Texto en los eventos de mensaje.** `content_preview` existe solo para armar el aviso push sin
que `notifications` llame a `messaging`. Son unos 140 caracteres: las menciones de rol se
reemplazan por `@rol`, las de usuario se dejan como `<@id>` (cada una cuenta como los 8 caracteres
de `@usuario` y el corte nunca la parte) para que `notifications` ponga el nombre desde su réplica
(`@Ana`, o `@usuario` si no lo conoce), los espacios se compactan, y si el mensaje tiene solo
archivos dice `Archivo adjunto`. Sin texto ni archivos no viaja. `notifications` lo usa y lo
descarta; no lo guarda. `channel_name` evita buscar el nombre del canal.

**Presencia para el push.** Se publica (por el outbox) cuando cambia el par (conexiones, "No
molestar") de un usuario, no cuando cambia su estado visible: `connections` es el estado real de
sus conexiones (ignora el modo invisible, que no importa para saber si la app está abierta) y
`do_not_disturb` es verdadero con el estado manual "No molestar". Conectar una segunda pestaña
activa no publica nada. `version` es la de la presencia del usuario y crece siempre.

Los consume `notifications` (no leídos, menciones, historial y push). El contrato vive en
[`events-contract`](https://github.com/discordia-grupo01/events-contract) y en el AsyncAPI de `docs`.

La propagación de mensajes enviados entre instancias es un detalle interno de escalado
(`messaging.broadcast`, ver ADR), no un evento de dominio para otros servicios. Lo que viaja por ahí
es siempre `new_message`, `message_updated`, `message_deleted`, `reaction_updated`, `new_dm`,
`mention`, `access_revoked`, `server_left`, `server_suspended` y `server_reactivated`, y todo sale
por el outbox. Las excepciones salen directo al fanout:
`disconnect` (corte de los sockets de un usuario suspendido, ver "Usuarios suspendidos") y
`presence_updated` y `own_status_updated`, que son efímeros: reintentar uno viejo sería peor que
perderlo.

## Outbox
Antes, guardar un mensaje en Mongo y avisarle a las demás instancias por RabbitMQ eran dos
pasos sueltos: si el proceso moría, o RabbitMQ no respondía, entre uno y otro, el aviso se
perdía (y un fallo de RabbitMQ al enviar hasta cerraba el canal). Ahora el aviso queda
anotado primero en Postgres y un poller lo publica.

```
enviar mensaje ──▶ 1. anota el evento en Postgres (outbox_events)   ← si falla: MESSAGES_UNAVAILABLE (503)
                   2. escribe el mensaje en Mongo
                   3. responde OK al cliente
poller (cada 1 s, o apenas se anota) ──▶ completa Mongo si hace falta ──▶ publica en RabbitMQ
                                         ──▶ espera la confirmación del broker ──▶ marca publicado
                                         ──▶ si publicó algo, vuelve a mirar sin esperar
```

- **Qué pasa si algo se corta.** Proceso muerto entre 1 y 2: el poller ve la fila pendiente,
  hace el upsert del mensaje en Mongo (idempotente) y lo publica. RabbitMQ caído: los mensajes
  se siguen aceptando, quedan pendientes y salen en orden cuando vuelve (sin gastar
  reintentos). Mongo caído después de anotar: el mensaje ya está aceptado y el poller lo
  completa. Postgres caído: no se acepta el mensaje (`503 MESSAGES_UNAVAILABLE`) y no queda
  nada a medias; `/readyz` responde 503 con `detail: postgres`.
- **Garantía: al menos una vez.** Si el proceso muere justo entre publicar y marcar, el evento
  se publica dos veces con el mismo `id`. Los clientes deduplican por el `id` del mensaje; el
  servidor no guarda estado en memoria para esto.
- **Varias instancias.** Cada poller toma un lote con `FOR UPDATE SKIP LOCKED`, así que dos
  instancias nunca toman la misma fila. Dos eventos del mismo mensaje (editar, borrar) nunca
  salen juntos: el segundo espera a que el primero esté publicado, así llegan en orden. Como
  cada consulta libera solo un evento por mensaje, el poller vuelve a consultar **de inmediato**
  mientras publique algo (los 3 eventos de un mensaje directo salen en milisegundos y no en 3 s);
  si todo falla espera el intervalo de 1 s, para no reintentar en un bucle.
- **Qué se guarda.** Tabla `outbox_events` (`migrations/0001_outbox_events.up.sql`): `id`
  (UUIDv7), `event`, `topic`, `payload` y `apply` (JSONB), `message_id`, `channel_id`,
  `created_at`, `published_at`, `attempts` y `last_error`. **Las filas no se borran** (auditoría).
  Al publicar se vacían `payload` y `apply`, así el texto de los mensajes no queda en Postgres;
  quedan el tipo de evento, los ids, las fechas, los intentos y el último error.
- **Reintentos.** Un RabbitMQ que no responde o no confirma se reintenta sin límite y sin contar.
  Una fila que no se puede interpretar cuenta un intento; a los 10 deja de intentarse (queda
  visible en la tabla para revisarla).

### Postgres y Supabase
Local (`docker compose` de `infrastructure`): un Postgres propio en el puerto 5435, con las
migraciones aplicadas por el servicio `messaging-migrations`. Para correrlo en el host:
```bash
cp .env.example .env     # trae DATABASE_* para el Postgres local
make migrate             # aplica migrations/*.up.sql (golang-migrate en Docker)
```
Producción (Supabase), una sola vez:
1. En el SQL Editor: `CREATE SCHEMA IF NOT EXISTS messaging;`. Que `messaging` **no** esté en
   Settings > API > Exposed schemas.
2. Botón **Connect**, pestaña **Session pooler** (no "Direct connection", que solo resuelve por
   IPv6, ni "Transaction pooler", que no sostiene el `search_path`): host
   `aws-0-<región>.pooler.supabase.com`, puerto `5432`, base `postgres`, usuario
   `postgres.<project-ref>`.
3. Secrets del repo (Settings > Secrets and variables > Actions): `PROD_DATABASE_HOST`,
   `PROD_DATABASE_PORT`, `PROD_DATABASE_NAME`, `PROD_DATABASE_USER`, `PROD_DATABASE_PASSWORD`,
   `PROD_DATABASE_SSLMODE=require` y `PROD_DATABASE_SCHEMA=messaging`. En cada push a `main` el
   CI corre `make migrate` contra producción (job `migrate`, después de publicar la imagen y
   **antes** del deploy: si una migración falla, no se despliega).
4. En la VM, `~/messaging.env`: `DATABASE_HOST`, `DATABASE_PORT`, `DATABASE_NAME`,
   `DATABASE_USER`, `DATABASE_PASSWORD`, `DATABASE_SSLMODE=require` y `DATABASE_SCHEMA=messaging`.
   Hay que recrear el contenedor (el próximo deploy lo hace).

Como la migración corre antes del deploy, si el smoke test falla y `deploy.sh` vuelve a la
imagen anterior, esa imagen corre contra el schema nuevo: las migraciones tienen que ser
compatibles con la versión anterior (agregar, no renombrar ni borrar).

## Endpoints / Channels
- WS `/socket`, channel `"channel:" <> channel_id` (`MessagingWeb.RoomChannel`):
  - `join` con `{"last_message_id": "<id>"}` opcional -- valida canal y que el
    usuario tenga `VIEW_CHANNELS`. Si viene `last_message_id`, empuja
    `"missed_messages"` con lo enviado después de ese mensaje (ver
    [Historial y reconexión](#historial-y-reconexión)).
  - `handle_in("edit_message", %{"id" => "<id>", "content" => "..."})` -- edita un
    mensaje propio (ver [Editar mensajes](#editar-mensajes)).
  - `handle_in("delete_message", %{"id" => "<id>"})` -- elimina un mensaje propio, o
    ajeno con `MANAGE_MESSAGES` (ver [Eliminar mensajes](#eliminar-mensajes)).
  - `handle_in("delete_message", ...)` y `handle_in("edit_message", ...)` valen también en una
    conversación directa (ver [Mensajes directos](#mensajes-directos-dm)).
  - `handle_in("new_message", %{"content" => "...", "client_id" => "..."})` -- requiere
    `SEND_MESSAGES` en cada envío (CA1-CA4 de "Enviar mensaje"). Responde `ok` con el mensaje
    creado. `client_id` es opcional (ver [Reintentos sin duplicar](#reintentos-sin-duplicar)).
  - `handle_in("add_reaction" | "remove_reaction", %{"message_id" => "<id>", "emoji" => "👍"})`
    -- reacciona a un mensaje o saca la reacción propia (ver [Reacciones](#reacciones)).
- WS `/socket`, channel `"user:" <> user_id` (`MessagingWeb.UserChannel`, solo el propio usuario):
  - `handle_in("send_dm", %{"to" => "<user id>", "content" => "...", "client_id" => "..."})` --
    envía un mensaje directo (ver [Mensajes directos](#mensajes-directos-dm)); emite `new_dm`.
    `client_id` es opcional (ver [Reintentos sin duplicar](#reintentos-sin-duplicar)).
  - Recibe `mention` cuando alguien te menciona (ver [Menciones](#menciones)).
  - `handle_in("set_status", ...)` y `handle_in("activity", ...)`: ver
    [Estado de actividad](#estado-de-actividad).
- WS `/socket`, channel `"presence:" <> server_id` (`MessagingWeb.PresenceChannel`): ver
  [Estado de actividad](#estado-de-actividad).
- `GET /v1/presence?user_ids=a,b,c`: ver [Estado de actividad](#estado-de-actividad).
- `GET /v1/mentions` y `POST /v1/channels/:channel_id/mentions/read` -- ver
  [Menciones](#menciones).
- `GET /v1/messages?ids=a,b,c` -- trae varios mensajes por id (ver
  [Mensajes por id](#mensajes-por-id)).
- `GET /v1/conversations` y `POST /v1/conversations/:id/read` -- ver
  [Mensajes directos](#mensajes-directos-dm).
- `POST /v1/blocks`, `DELETE /v1/blocks/:user_id` y `GET /v1/blocks` -- ver
  [Bloquear y desbloquear usuarios](#bloquear-y-desbloquear-usuarios).
- `PATCH /v1/channels/:channel_id/messages/:message_id` con `{"content": "..."}` --
  edita un mensaje propio (ver [Editar mensajes](#editar-mensajes)).
- `DELETE /v1/channels/:channel_id/messages/:message_id` -- elimina un mensaje (ver
  [Eliminar mensajes](#eliminar-mensajes)).
- `GET /v1/channels/:channel_id/messages?limit=&before=<id>&after=<id>&around=<id>` --
  historial paginado por cursor, cada página en orden cronológico. Requiere
  `VIEW_CHANNELS`. `around` trae el historial alrededor de un mensaje (ver
  [Historial y reconexión](#historial-y-reconexión)).
- `GET /v1/servers/:server_id/messages/search?q=&author_id=&channel_id=&limit=&before=` --
  busca mensajes del servidor (ver [Buscar mensajes](#buscar-mensajes)).
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

## Reintentos sin duplicar

`new_message` y `send_dm` aceptan un `client_id` opcional (string de 1 a 64 caracteres): un id que
genera el cliente para ese envío. Sirve para reintentar sin crear el mensaje dos veces cuando no se
sabe si el primer intento llegó (por ejemplo, un timeout).

- **Id determinístico.** Con `client_id`, el id del mensaje no se sortea: sale de un UUID v5 de
  `channel_id`, `user_id` y `client_id`. El mismo envío siempre da el mismo `id`, y un `client_id`
  ajeno nunca pisa mensajes de otro usuario ni de otro canal. Sin `client_id` todo sigue igual
  (UUID v7).
- **Reintento secuencial.** Antes de reclamar adjuntos se busca el mensaje por ese `id`: si ya
  existe se devuelve tal cual y no se vuelve a anotar nada (ni `new_message`, ni `new_dm`, ni
  menciones, ni `last_message`).
- **Reintento a la vez que el primero.** Los dos pedidos calculan el mismo `id`. Mongo acepta un solo
  insert por `_id` y el `upsert` del outbox es idempotente, así que queda un único documento. El
  aviso puede salir dos veces con el mismo `id`; los clientes ya deduplican por `id`.
- **Con adjuntos.** Los `attachment_ids` se reclaman una sola vez: un reintento concurrente con los
  mismos adjuntos responde `INVALID_ATTACHMENT` mientras el primero sigue en curso.
- **Se devuelve.** El mensaje incluye `client_id` en la respuesta, en `new_message`, `new_dm`, el
  historial y `missed_messages`, para que quien envió reconozca su propio mensaje.
- **Respuesta de `new_message`.** Es `ok` con el mensaje creado (igual que `send_dm`).
- **Valor inválido** (no es string, vacío o de más de 64): `INVALID_PAYLOAD`.

## Editar mensajes
Un mensaje se edita por REST (`PATCH /v1/channels/:channel_id/messages/:message_id`,
cuerpo `{"content": "..."}`) o por el socket (`edit_message` con `{"id", "content"}`):
las dos entradas usan la misma función de dominio (`Messaging.Chat.edit_message/1`).

- **Solo el autor.** Otro usuario recibe `403 NOT_MESSAGE_AUTHOR` (por el socket, el
  mismo código en la respuesta de error). Además tiene que seguir pudiendo escribir en
  el canal (`SEND_MESSAGES`): si lo sacaron o le revocaron el permiso, `403 FORBIDDEN`.
- **Mismas reglas que al enviar:** el contenido se recorta, no puede quedar vacío
  (`EMPTY_CONTENT`) ni superar los 2000 caracteres (`MESSAGE_TOO_LONG`). Un mensaje que
  no existe, o que es de otro canal, da `404 MESSAGE_NOT_FOUND`. Un cuerpo sin `content`
  de tipo string da `400 INVALID_PAYLOAD`.
- **Marca de edición.** Todo mensaje trae `edited` (`true`/`false`) y `edited_at`
  (ISO 8601 en UTC, o `null`). Los mensajes anteriores a esta función, que no tienen el
  campo guardado, salen como `edited: false`. El orden del historial no cambia: se
  sigue ordenando por `inserted_at`, que la edición no toca.
- **Sin cambios, sin ruido.** Si el contenido nuevo (ya recortado) es igual al actual, la
  respuesta es `200` con el mensaje tal cual, **no** se marca como editado y no se emite
  nada.
- **Tiempo real.** Al editar, el mensaje completo se emite a quien tenga el canal abierto
  como evento `message_updated` (mismo formato que `new_message`, ya con `edited: true`).
  Viaja por el mismo fanout de RabbitMQ que `new_message`, así que llega también a los
  clientes conectados a otra instancia. El cuerpo en el fanout pasó a ser
  `{"event": ..., "payload": ...}`; el consumidor sigue aceptando el formato anterior
  (el mensaje "pelado") como `new_message` y descarta los eventos que no conoce. Si el
  broadcast fallara (RabbitMQ caído), la edición queda guardada y se responde igual
  `200`/`ok`; solo se pierde el aviso en vivo.
- **Concurrencia.** Si dos ediciones del mismo mensaje llegan a la vez, gana la última
  que escribe. La escritura filtra por id, canal y autor, así que ni siquiera una
  carrera puede modificar un mensaje ajeno.
- **Ediciones mientras estabas desconectado.** Ver
  [Cambios mientras estabas desconectado](#cambios-mientras-estabas-desconectado).

## Historial y reconexión

**Historial (REST).** `GET /v1/channels/:id/messages?limit=50` devuelve los
mensajes más recientes **de más viejo a más nuevo** (`limit` máx. 100). Si hay
más, `next_cursor` trae el id del mensaje más viejo de la página; se pide la
página anterior con `?before=<next_cursor>` hasta que `next_cursor` sea `null`.
`?after=<id>` hace lo inverso: devuelve lo posterior a ese mensaje, también en
orden cronológico. `before` y `after` no se pueden combinar y el cursor tiene
que ser un mensaje de ese mismo canal (si no, `400 INVALID_CURSOR`).

**Alrededor de un mensaje.** `?around=<id>` devuelve ese mensaje con hasta
`limit / 2` mensajes antes y `limit / 2` después, en orden cronológico. Sirve
para saltar a un resultado de la [búsqueda](#buscar-mensajes) aunque esté muy
atrás en el historial. Además de `next_cursor` (hay más viejos: pasarlo como
`before`), la respuesta trae `newer_cursor` (hay más nuevos: pasarlo como
`after`); cuando `newer_cursor` es `null` se llegó al presente. `around` no se
combina con `before` ni `after` (`400 INVALID_CURSOR`), y si el mensaje no
existe, es de otro canal o fue eliminado responde `404 MESSAGE_NOT_FOUND`.

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

Para enterarse además de lo que **cambió** (hoy, ediciones) en mensajes que ya tenía,
ver [Cambios mientras estabas desconectado](#cambios-mientras-estabas-desconectado).

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

## Mensajes por id

`GET /v1/messages?ids=<id>,<id>,...` devuelve los mensajes pedidos (de 1 a 50 ids
separados por coma; repetidos y espacios se descartan) como `{"messages": [...]}`,
en el orden pedido y con la misma forma que el historial. Sirve para mostrar el
texto de cada entrada de `GET /v1/notifications/history`, que solo guarda ids.

- **Permisos:** un mensaje sale solo si el canal existe y el usuario puede verlo
  (`VIEW_CHANNELS`, o ser parte de la conversación en un DM). Los que no cumplen,
  los eliminados y los ids que no existen se **omiten sin avisar**: la respuesta no
  revela si un mensaje existe en un canal ajeno. Por eso puede traer menos
  mensajes que ids pedidos.
- **Errores:** `400 INVALID_PAYLOAD` si falta `ids`, viene vacío o tiene más de 50;
  `503 MESSAGES_UNAVAILABLE` si no se pudo leer Mongo; `401` sin JWT.
- No trae reacciones (para eso está el historial del canal).

## Eliminar mensajes
Un mensaje se elimina por REST (`DELETE /v1/channels/:channel_id/messages/:message_id`,
responde `204` sin cuerpo) o por el socket (`delete_message` con `{"id"}`): las dos
entradas usan la misma función de dominio (`Messaging.Chat.delete_message/1`).

- **Quién puede.** El **autor** del mensaje, o un miembro con el permiso `MANAGE_MESSAGES`
  en el canal (el del servidor más los overrides del canal; los administradores y el dueño lo tienen implícito; se agregó al catálogo
  de `servers` y no viene en el conjunto por defecto de un rol nuevo). Cualquier otro
  recibe `403 MESSAGE_DELETE_DENIED`.
- **Orden de las comprobaciones.** Canal (404 si no existe o no es de texto) → el usuario
  tiene que poder ver el canal (`VIEW_CHANNELS`, si no `403 FORBIDDEN`) → el mensaje existe
  en ese canal y no está borrado (si no `404 MESSAGE_NOT_FOUND`) → autoría o
  `MANAGE_MESSAGES`. Como el autor se resuelve sin consultar nada más, borrar lo propio
  cuesta una sola consulta a `servers`; la de moderación se hace solo cuando el que borra
  no es el autor. Quien dejó el servidor ya no puede ver el canal, así que tampoco puede
  borrar sus mensajes viejos.
- **Qué se guarda.** Es un borrado lógico: el documento queda como marcador
  (`deleted_at`, `changed_at`) y el `content` se vacía, así que el texto **no** se conserva.
  Se mantienen el id, el autor y `inserted_at` a propósito: un cliente cuyo último
  mensaje fue borrado sigue pudiendo usarlo como cursor (`last_message_id`/`after`/`before`)
  sin recibir `INVALID_CURSOR`.
- **Deja de mostrarse.** El historial por REST y `missed_messages` filtran los borrados;
  el marcador no vuelve en ninguna lista. Editar un mensaje borrado da `404`, y la escritura
  filtra por `deleted_at` para que ni una carrera lo resucite.
- **Borrar dos veces.** La segunda vez responde `404 MESSAGE_NOT_FOUND`: para la API el
  mensaje ya no existe.
- **Tiempo real.** Se emite a quien tenga el canal abierto el evento `message_deleted` con
  `{"id", "channel_id", "server_id", "deleted_at"}`, sin el contenido ni el autor. Viaja por
  el mismo fanout de RabbitMQ que `new_message` y `message_updated`. Si el broadcast fallara,
  el borrado queda guardado y se responde igual `204`/`ok`; solo se pierde el aviso en vivo.
- **Clientes desconectados.** Reciben los ids borrados en `changed_messages.deleted_ids`
  al reconectar (ver más abajo).
- **Marcadores.** Nadie los limpia: cada uno ocupa unos 200 bytes y no tiene texto. Si algún
  día hiciera falta, un TTL sobre `deleted_at` los purgaría solo, pero un cliente que vuelva
  después de ese plazo no se enteraría de los borrados viejos (habría que pedirle recargar
  el historial).

## Mensajes directos (DM)
Una conversación directa es un **canal sin servidor** (`kind: "dm"`) que `messaging` crea y guarda
él mismo en su colección `channels`; **no** nace de ningún evento de `servers`. Por eso el historial,
la paginación, editar, borrar y el feed de cambios son los mismos que en un canal de servidor.
Lo único que cambia es quién puede hacer qué (ver más abajo).

**Enviar.** Por el socket, en la sala personal `user:<tu id>` (cada usuario se une solo a la suya;
otra sala devuelve `FORBIDDEN`):

```
push "send_dm" {"to": "<id del destinatario>", "content": "hola"}
reply ok {"conversation_id": "...", "message": {...}}
```

- **Se crea al primer mensaje.** No existe ningún endpoint para "abrir" una conversación: mientras
  nadie escriba, no hay nada guardado. La primera vez se valida que el destinatario exista
  en la réplica local de usuarios (`404 RECIPIENT_NOT_FOUND` si no figura; un usuario recién
  registrado figura a los pocos segundos) y se crea la conversación; los mensajes siguientes ya
  no consultan nada. Si Mongo no responde: `503 USERS_UNAVAILABLE`.
- **Un solo canal entre dos personas.** El id de la conversación es un UUID v5 del par de usuarios
  ordenado, así que da lo mismo quién escribe primero y dos primeros mensajes simultáneos caen en el
  mismo documento (el alta es un upsert con `$setOnInsert`).
- **Reglas del mensaje.** Mismas que al enviar a un canal (se recorta, no vacío, máx. 2000). No se
  puede enviar a uno mismo (`400 CANNOT_MESSAGE_SELF`). El id del destinatario solo admite
  `[A-Za-z0-9_-]` (hasta 64): lo demás da `RECIPIENT_NOT_FOUND` sin llegar a ningún servicio.
- **`new_message` en una conversación se rechaza** (`CHANNEL_NOT_TEXT`): los DM se envían siempre
  con `send_dm`, para que no haya dos puertas.
- **Reintentos.** `send_dm` acepta el mismo `client_id` opcional que `new_message`
  (ver [Reintentos sin duplicar](#reintentos-sin-duplicar)).

**Recibir en tiempo real.** Cada envío emite:
- `new_dm` a la sala personal de **los dos** participantes, con
  `{"conversation_id", "partner_id", "message": {...}}` (`partner_id` es el *otro* participante
  para cada destinatario, igual que en `GET /v1/conversations`). Es lo que permite que un DM
  **nuevo** le aparezca a quien lo recibe sin recargar ni tener nada abierto: todavía no existía la
  sala de esa conversación, así que no habría dónde avisarle. Al emisor le sirve para sus otras
  pestañas.
- `new_message` a la sala `channel:<conversation_id>` (para quien tiene la conversación abierta, igual
  que en un canal). Un cliente unido a las dos salas recibe el mismo mensaje dos veces: se
  deduplica por `message.id`.

**Pendiente de lectura.** Si el destinatario no está conectado el mensaje queda guardado, y al volver
lo ve como no leído. La conversación guarda el último mensaje (`last_message_at`,
`last_message_user_id`) y, por participante, hasta dónde leyó (`last_read_at`). Está sin leer para
alguien si el último mensaje es del otro y es posterior a lo que ya leyó. El emisor nunca tiene su
propia conversación sin leer.

**REST.**
- `GET /v1/conversations?limit=` -- mis conversaciones (solo las que tienen al menos un mensaje), la
  más reciente primero (default 50, máx. 100; todavía sin paginación). Cada una trae `id`,
  `partner_id`, `unread`, `last_message_at` y `last_message` (`null` si ese mensaje se eliminó).
  Solo ids: ningún dato del perfil del otro usuario (nombre, foto, email), que se pide a
  `identify-service`. La réplica de usuarios guarda solo `user_id` y `version`.
- `POST /v1/conversations/:id/read` -- marca como leído hasta el último mensaje que hoy tiene la
  conversación (`204`). Un mensaje que llegue después sigue sin leer.
- `GET /v1/channels/:id/messages` -- historial de la conversación (con el `id` de la conversación).

**Autorización.** Se elige según el `kind` del canal (`Messaging.Chat.Access`): `Server` (consulta
a `servers`) o `Direct`. En un DM puede ver y escribir quien participa, y **nadie modera**: editar y
borrar son solo del autor (`NOT_MESSAGE_AUTHOR` / `MESSAGE_DELETE_DENIED`). Alguien que no
participa recibe `404 CHANNEL_NOT_FOUND`, **igual que si la conversación no existiera**: como el id es
derivable de dos ids de usuario, un `403` revelaría que esas dos personas hablaron. Los mensajes de
un DM llevan `server_id: null`.

**Límite conocido.** Si falla solo la actualización del último mensaje de la conversación (la
escritura que la ordena y la marca como no leída), el mensaje igual se entrega y se loguea un
warning; el estado "no leído" se corrige con el siguiente mensaje.

## Bloquear y desbloquear usuarios
Los bloqueos son una relación entre dos usuarios que vive en `messaging` (colección `blocks`, un
documento por par `bloqueador:bloqueado`, con índice por bloqueador). Están en `messaging` y no en
`identify-service` para que cada DM los verifique con **una sola consulta local por `_id`**, sin una
llamada más entre servicios que pueda caerse.

- `POST /v1/blocks` con `{"user_id": "..."}` -- bloquea (`204`). Es idempotente. El id viaja en el
  cuerpo y no en la URL. Un cuerpo sin `user_id` string da `400 INVALID_PAYLOAD`. Verifica que el usuario exista en la
  réplica local (`404 USER_NOT_FOUND`; si Mongo no responde, `503 USERS_UNAVAILABLE`). No se puede
  bloquear a uno mismo (`400 CANNOT_BLOCK_SELF`).
- `DELETE /v1/blocks/:user_id` -- desbloquea (`204`). Es idempotente y **no** consulta la
  réplica de usuarios: se puede desbloquear a alguien que ya no existe.
- `GET /v1/blocks?limit=` -- a quién bloqueé, el más reciente primero (default 50, máx. 100). Cada
  elemento trae solo `user_id` y `created_at`. **Nunca** se informa quién te bloqueó a vos.
- `GET /v1/conversations` suma `blocked_by_me` en cada conversación, para que el cliente muestre
  "desbloquear" sin otra consulta. No existe el campo inverso.

**Efecto sobre los DM.** El bloqueo vale en las dos direcciones, para **enviar**:
- Quien fue bloqueado recibe `403 DM_NOT_DELIVERED` ("No se pudo entregar el mensaje."). El mensaje
  **no se guarda**, no se crea la conversación si era la primera vez, no se consulta la
  réplica de usuarios y nadie recibe ningún evento.
- Quien bloqueó recibe `403 USER_BLOCKED` si intenta escribirle a esa persona: tiene que
  desbloquearla primero. Es información propia, así que se le dice.
- Se comprueba en **cada** mensaje, no solo en el primero, así que aplica también a conversaciones que
  ya existían. Si la consulta de bloqueos falla, el mensaje no se envía (nunca se interpreta un error
  como "sin bloqueo").
- **Editar y borrar** mensajes en un DM bloqueado también se rechaza (`403 FORBIDDEN`), para los dos. La
  conversación queda **congelada**: editar es escribirle contenido nuevo a la otra persona, y borrar
  cambia un historial que la historia pide conservar (además, quien fue bloqueado podría borrar lo que
  escribió y destruir una prueba antes de que la otra persona lo denuncie).
- **Se conserva todo lo previo.** El historial por REST, la lista de conversaciones y marcar como leído
  siguen funcionando para los dos.
- Al desbloquear, los dos vuelven a poder escribirse, editar y borrar.

**Efecto sobre el estado de actividad.** Ninguno de los dos ve al otro en línea.

**Privacidad.** `DM_NOT_DELIVERED` no dice por qué. Hoy la única causa posible es el bloqueo, así que
quien se fije puede deducirlo; es el mismo compromiso que hacen otras apps de mensajería. A cambio,
el bloqueado nunca ve cuándo ni si el otro lo bloqueó, y no hay forma de listar quién te bloqueó.

**Qué queda registrado.** La relación se guarda en la base (`blocks`: quién, a quién y cuándo), porque
hace falta para aplicarla. En los logs, el código de `messaging` no escribe ninguna línea de bloqueo
(solo avisos de fallo, con el motivo y sin ids). Pero el log HTTP del framework sí registra
`DELETE /v1/blocks/<id>` al desbloquear (al bloquear, con `POST`, el id va en el cuerpo y solo
aparece en nivel debug entre los parámetros). Ahí **no** figura quién bloqueó
(sale del JWT, que no se loguea), así que no alcanza para saber quién bloqueó a quién, pero el id del
bloqueado sí queda en esa línea. No revisé los logs de acceso de Kong.

**Llamadas privadas.** La historia las menciona, pero todavía no existen. Cuando existan, la
verificación es `Messaging.Chat.Blocks.check_contact/2`.

## Estado de actividad
Cada usuario se ve `online`, `idle`, `dnd` u `offline`, y los cambios llegan en tiempo real a quien
mira la lista de miembros de un servidor o la lista de mensajes directos.

**Qué ven los demás:**

| Situación | Estado |
|---|---|
| Sin conexiones abiertas | `offline` |
| Eligió `invisible` | `offline` |
| Eligió `dnd` o `idle` | eso, aunque esté inactivo |
| Eligió `online` y todas sus conexiones están inactivas | `idle` |
| Eligió `online` y alguna conexión está activa | `online` |

Lo elegido se guarda en Mongo (colección `presence`) y se conserva entre sesiones. Cada pestaña o
celular conectado es una conexión aparte.

**Canal `user:<id>`:**
- El `join` registra la conexión y responde `{"status", "idle_after_ms"}`.
- `set_status` con `online`, `idle`, `dnd` o `invisible`. Todas las sesiones del usuario reciben
  `own_status_updated`.
- `activity` con `{"state": "idle" | "active"}`: lo manda el cliente después de `idle_after_ms` sin
  interacción, y cuando vuelve.
- Recibe `presence_updated` de sus contactos de DM.

**Canal `presence:<server_id>`:** solo para miembros. El `join` responde
`{"presences": [{"user_id", "status", "version"}]}` con los que no están `offline`, y después llega
`presence_updated` con cada cambio. Si el usuario sale del servidor, el canal se cierra.

**`GET /v1/presence?user_ids=a,b,c`:** el estado de hasta 100 usuarios, en el mismo orden.

Cada evento trae `version`: el cliente se queda con la más alta por usuario.

**Desconexión.** `Messaging.Presence.Tracker` vigila el proceso de cada canal `user:<id>`: cuando
termina, por el motivo que sea, la conexión se borra. Si se cae una instancia entera,
`Messaging.Presence.Sweeper` borra sus conexiones cuando deja de escribir su heartbeat.

**Bloqueos.** Dos usuarios con un bloqueo entre ellos se ven siempre `offline`.

| Variable | Default | Qué es |
|---|---|---|
| `PRESENCE_IDLE_MS` | `300000` | Inactividad tras la que el cliente se reporta ausente |
| `PRESENCE_INSTANCE_HEARTBEAT_MS` | `10000` | Cada cuánto escribe cada instancia que sigue viva |
| `PRESENCE_INSTANCE_STALE_MS` | `30000` | Tiempo sin escribir para dar una instancia por caída |

## Menciones
Historia #46. Las menciones van **dentro del texto** como tokens, que arma el
cliente al elegir a alguien del autocompletado:

| Token | Menciona a |
|---|---|
| `<@USER_ID>` | un usuario |
| `<@&ROLE_ID>` | un rol |
| `@everyone` | todos los que pueden ver el canal |

Un `@nombre` suelto es texto común: solo cuenta lo que tiene id. `@here` no
existe. En mensajes directos los tokens quedan como texto.

**Al enviar** (`new_message`), si el texto tiene algún token, `messaging` decide
qué menciones valen con la réplica local de miembros, roles y overrides (ver
"Réplica local de permisos y usuarios"), con las reglas de la historia:

- **CA1:** un usuario mencionado cuenta si es miembro del servidor. No hace
  falta ningún permiso.
- **CA2 / CA3:** los roles y `@everyone` cuentan solo si el autor tiene
  `MENTION_EVERYONE` (el dueño y los administradores lo tienen siempre).
- **CA4:** sin ese permiso, se descartan y el mensaje se envía
  igual, con eso como **texto plano**. No es un error.
- Se notifica a quienes pueden ver **ese canal** (`VIEW_CHANNELS` ya con los
  overrides del canal), nunca al autor.

El mensaje guarda lo que valió en `mentions`, `mention_roles` y
`mention_everyone` (siempre presentes en la API; `[]`/`false` en mensajes
viejos), así el cliente resalta "me mencionaron" sin más llamadas.

Por cada destinatario:

1. Se guarda una notificación en la colección `mentions`
   (`_id = "<message_id>:<user_id>"`, así nunca se duplica).
2. Se emite `mention` en su sala personal `user:<id>`:
   ```json
   { "server_id": "...", "channel_id": "...", "message": { /* Message */ } }
   ```

**Para quien estaba desconectado:** `GET /v1/mentions?limit=` devuelve las no
leídas, la más nueva primero, con su mensaje. `POST
/v1/channels/:channel_id/mentions/read` las marca como leídas (por ejemplo, al
abrir el canal).

**Editar** vuelve a chequear las menciones con los permisos actuales del
autor: los que dejan de estar mencionados salen de su bandeja, y solo los
nuevos reciben `mention` (corregir un typo no vuelve a pinguear a nadie).
**Eliminar** un mensaje borra sus notificaciones. Borrar el canal o el
servidor también.

Si Mongo no responde, el envío (o la edición) falla con
`MENTIONS_UNAVAILABLE` (503), igual que ya pasa con el chequeo de
`SEND_MESSAGES`. Si el autor no figura como miembro en la réplica, también
(en la práctica no pasa: antes se le exigió `SEND_MESSAGES`).

## Palabras prohibidas
Cada servidor puede tener una lista de palabras o frases prohibidas, que se
edita en `servers` (`PUT /v1/servers/{id}/banned-words`, con `MANAGE_MESSAGES`)
y llega acá por `servers.word_filter_updated`.

- `new_message` y `edit_message` (y el `PATCH` de edición) rechazan un mensaje
  que contenga alguna: responden `BANNED_WORD` con las encontradas en
  `details.words`, y no se guarda ni se emite nada. Una edición que deja el
  mensaje igual no se chequea.
- Se compara sin distinguir mayúsculas ni tildes ("Tónto" = "tonto") y solo por
  palabras completas: "película" no choca con "culo". Una frase ("no sirve")
  tiene que aparecer con esas palabras seguidas, sin importar la puntuación o
  los espacios entre ellas. No detecta variantes escritas para esquivarlo
  ("t0nt0", "t.o.n.t.o").
- Nadie queda exento, ni el dueño. Se chequea después de los permisos, así que
  quien no puede escribir recibe `FORBIDDEN` y nunca ve la lista.
- Aplica desde que llega el evento: los mensajes ya enviados no se tocan. En
  los mensajes directos no aplica (la lista es de cada servidor).

## Emojis personalizados
`discordia-servers` es el dueño de los emojis (`/v1/servers/{serverId}/emojis`). Este servicio
consume `servers.emoji_created` y `servers.emoji_deleted` en la cola `messaging.server_emojis` y los
guarda en `replica_emojis`. Los dos eventos traen el emoji completo y el borrado gana sin importar
el orden en que lleguen. Los emojis borrados se quedan en la réplica; al borrar un servidor se van
los suyos.

En mensajes y reacciones un emoji se escribe `<:nombre:id>`, o `<a:nombre:id>` si es animado.

**Para usar uno** tiene que existir, no estar borrado, coincidir en nombre y en animado, y ser de
un servidor donde seas miembro. Además hace falta Premium si es animado, si es de otro servidor o
si va en un mensaje directo. Si no se cumple responde `403 CUSTOM_EMOJI_NOT_ALLOWED`, y
`503 CUSTOM_EMOJIS_UNAVAILABLE` si no se pudo verificar.

- **Editar un mensaje** solo valida los emojis nuevos: quien perdió Premium, o tiene en el mensaje
  un emoji que se borró, puede seguir editándolo.
- **Sacar una reacción** no valida el emoji, por el mismo motivo.
- **Texto que solo se parece** a un token (un id que no es UUID, por ejemplo) es texto común.

**Para dibujarlos**, `GET /v1/custom-emojis?ids=<id>,<id>` (hasta 100) devuelve nombre e imagen.
Incluye los borrados y no pide ser miembro, porque un mensaje puede traer el emoji de un servidor
donde quien lee no está. Si un id no aparece (se borró su servidor), el cliente muestra `:nombre:`.

**Si la cola no existía** cuando `servers` publicó, esos eventos se perdieron: RabbitMQ no los
guarda. Por ahora no hay backfill, así que hay que desplegar este consumidor antes de crear emojis.

## Reacciones
Historia #48: reaccionar a un mensaje con un emoji, en canales de servidor y en
conversaciones directas.

- **Agregar** (`add_reaction`): pide `ADD_REACTIONS` en el canal (lo calcula la
  réplica de permisos, con los overrides del canal; el owner y los administradores
  siempre pueden). En un DM alcanza con ser participante y que ninguno haya
  bloqueado al otro, igual que para escribir. Un miembro silenciado no reacciona.
- **Sacar** (`remove_reaction`): solo la reacción propia, y alcanza con ver el canal:
  quien perdió `ADD_REACTIONS` puede retirar las que ya había puesto.
- **Emoji**: tiene que ser exactamente un emoji (un grafema; vale 👨‍👩‍👧, 👍🏽, 🇦🇷 o
  1️⃣); texto o varios emojis dan `INVALID_EMOJI`. Un mensaje admite hasta 20 emojis
  distintos (`TOO_MANY_REACTIONS`); los que ya están se pueden seguir usando.
- **Idempotente**: son dos acciones explícitas y no un "toggle", así un doble click o
  un reintento no deshacen nada. Repetir una reacción, o sacar una que no estaba,
  responde `ok` sin emitir nada.

La respuesta trae `{"emoji", "count", "reacted_by_me"}`. Si algo cambió, se emite a
todos los que tienen el canal abierto:

```json
"reaction_updated": {"channel_id", "message_id", "emoji", "user_id",
                     "action": "added" | "removed", "count": 3}
```

`reacted_by_me` no viaja en el evento (es el mismo para todos): cada cliente usa el
`count` que manda el servidor y, si `user_id` es el suyo, actualiza su `reacted_by_me`.

El historial (`GET /messages`, `missed_messages`, `changed_messages`) trae
`reactions: [{"emoji", "count", "reacted_by_me"}]` en cada mensaje, calculado para
quien pide, en el orden en que se usó cada emoji. `new_message` y `message_updated`
no la traen: el cliente conserva las que ya tenía.

Se guardan en la colección `reactions`, un documento por mensaje, emoji y usuario
(`_id` = `"<message_id>:<emoji>:<user_id>"`, así dos reacciones iguales nunca se
duplican). Reaccionar mueve el `changed_at` del mensaje, así quien vuelve de una
desconexión recibe el mensaje en `changed_messages` con sus reacciones al día. Se
borran junto con el mensaje, el canal o el servidor.

## Adjuntar archivos
Se puede adjuntar a un mensaje (de un canal o directo) una imagen JPEG, PNG o WebP, o un PDF, de
hasta **10 MB** cada uno y hasta **5 por mensaje**. Con Premium el límite es **50 MB** y también se
pueden adjuntar **GIF**. Los archivos de hasta
10 MB viven en **Cloudinary** y los más grandes en **Supabase Storage**; en `messaging` (Mongo) solo
se guarda la URL y los metadatos, nunca los bytes, y el archivo tampoco se escribe en el disco del
servidor.

Es en dos pasos, porque los mensajes viajan por WebSocket y los archivos son binarios:

1. **Subir el archivo** por REST: `POST /v1/attachments?channel_id=<id>` (canal de un servidor) o
   `POST /v1/attachments?to=<user_id>` (mensaje directo), con el archivo como **cuerpo binario**
   del pedido (no multipart ni base64) y `?filename=` opcional con el nombre a mostrar.
   ```js
   const res = await fetch(`${API}/v1/attachments?channel_id=${channelId}&filename=${file.name}`, {
     method: 'POST',
     headers: { Authorization: `Bearer ${jwt}` },
     body: file,
   })
   const attachment = await res.json()
   ```
   Responde `201` con `{ id, url, name, content_type, size }`. Para subir hay que poder escribir
   ahí (`SEND_MESSAGES`, no estar silenciado, no estar bloqueado en el DM).
2. **Enviar el mensaje** con los ids, por el mismo WebSocket de siempre:
   ```json
   ["1","7","channel:<id>","new_message",{"content":"mirá esto","attachment_ids":["<id>"]}]
   ["1","8","user:<mi_id>","send_dm",{"to":"<user_id>","attachment_ids":["<id>"]}]
   ```
   `content` puede faltar o ir vacío si hay al menos un adjunto. El mensaje que reciben todos (y el
   historial) trae `attachments: [{ id, url, name, content_type, size }]`, siempre presente
   (`[]` si no tiene). Un adjunto se puede usar una sola vez, solo en el canal para el que se subió
   y solo por quien lo subió.

**Reglas (CA1 a CA3)**
- El formato se reconoce por el **contenido real** del archivo (sus primeros bytes), no por la
  extensión ni por el `Content-Type` que declare el cliente: un `.png` que en realidad es un
  ejecutable se rechaza, y un GIF solo se acepta si el usuario es Premium.
- `415 UNSUPPORTED_FILE_TYPE`: "Formato no soportado. Solo se aceptan imágenes JPEG, PNG o WebP y
  archivos PDF (y GIF con Premium)."
- `413 FILE_TOO_LARGE`: "El archivo supera el tamaño máximo permitido (10 MB, o 50 MB con
  Premium)." Si el pedido declara un `Content-Length` mayor que el límite del usuario, se rechaza
  sin leer el cuerpo. El límite sale de `billing.premium_updated` (colección `premium_users`).
- `400 EMPTY_FILE`, `400 INVALID_PAYLOAD` (hay que indicar `channel_id` o `to`, no los dos),
  `400 TOO_MANY_ATTACHMENTS`, `400 INVALID_ATTACHMENT` (no existe, ya se usó, es de otro canal o de
  otro usuario), `429 TOO_MANY_PENDING_ATTACHMENTS` (más de 20 subidos sin enviar) y
  `503 STORAGE_UNAVAILABLE`.
- Primero se chequean los permisos y después se lee el cuerpo, así que quien no puede escribir no
  hace que se lea un archivo entero.
- Los archivos tienen URL pública (de Cloudinary o de Supabase) con un identificador aleatorio
  `<canal>/<id>`: el nombre original nunca forma parte de la ruta.

**Subida directa desde el navegador.** La web guarda el JWT en una cookie httpOnly, así que el
navegador no lo tiene, y pasar el archivo por su backend en Vercel no sirve porque corta los pedidos
en 4,5 MB. Por eso:
1. El backend de la web pide `POST /v1/attachment-tickets` (con el Bearer normal) y recibe
   `{ "ticket": "...", "expires_in": 60 }`.
2. El navegador sube a `POST /v1/attachments/direct`, con el mismo query y el mismo cuerpo que
   `POST /v1/attachments`, y el header `X-Upload-Ticket: <ticket>` en vez de `Authorization`.

El ticket es de un solo uso (se gasta aunque el pedido falle), se guarda hasheado junto con los del
socket y no se puede usar para conectar el socket, ni al revés. Las reglas son las mismas de arriba.
Kong tiene que dejar pasar el archivo sin guardarlo antes (`request_buffering: false`): `messaging`
canjea el ticket al recibir el pedido, y con el archivo guardado primero, una subida lenta llegaría
con el ticket vencido.

**Editar** un mensaje no cambia sus adjuntos; si tiene adjuntos, se puede dejar el texto vacío.

**Huérfanos.** Cada subida queda registrada en la colección `attachments`. Un proceso
(`Messaging.Chat.AttachmentCleaner`, cada 10 minutos y apenas se borra un mensaje) borra del bucket
y de Mongo: los archivos subidos que no se adjuntaron a ningún mensaje en **24 horas**, los de un
mensaje eliminado, y los de un canal o servidor eliminado. Si el almacenamiento falla, el registro queda y
se reintenta en la próxima vuelta. Con varias instancias corren todas: borrar dos veces es
inofensivo.

**Variables de entorno**

| Variable | Qué es |
|---|---|
| `CLOUDINARY_URL` | `cloudinary://<API_KEY>:<API_SECRET>@<CLOUD_NAME>`, tal cual la muestra el Dashboard de Cloudinary (Settings > API Keys). El secreto es solo del servidor, nunca al navegador |
| `CLOUDINARY_FOLDER` | Carpeta donde se guardan los archivos (default `discordia/attachments`) |
| `CLOUDINARY_API_BASE_URL` | Solo para apuntar a otro host (default `https://api.cloudinary.com`) |
| `SUPABASE_URL` | URL del proyecto de Supabase donde van los archivos de más de 10 MB (`https://<ref>.supabase.co`) |
| `SUPABASE_SECRET_KEY` | Clave secreta `sb_secret_...` de ese proyecto. Es solo del servidor, nunca al navegador |
| `SUPABASE_STORAGE_BUCKET` | Bucket público donde se guardan (default `attachments`) |

Si falta alguna de las dos configuraciones, `messaging` arranca igual (loguea
`attachments_storage_not_configured`) y `POST /v1/attachments` responde `503` para los archivos que
van a ese almacenamiento. La ruta está en Kong (`messaging-attachments`, con JWT).

**Supabase Storage.** El plan gratis limita cada archivo a 50 MB, el total a 1 GB y la descarga a
5 GB por mes, y pausa el proyecto tras una semana sin uso. Si se pausa, las subidas de más de 10 MB
responden `503` y esos archivos no se pueden abrir hasta reactivarlo.

**Cloudinary y los PDF.** Las cuentas nuevas pueden traer bloqueada la entrega de PDF y ZIP (la URL
responde 401): se habilita en Settings > Security > "PDF and ZIP files delivery". La subida se hace
con `resource_type=auto`, y `messaging` guarda en `path` el tipo que Cloudinary asignó
(`image/<public_id>`, `raw/<public_id>`) para poder borrar el archivo después.

## Buscar mensajes
Historia #49. `GET /v1/servers/:server_id/messages/search?q=&author_id=&channel_id=&limit=&before=`

- `q` busca el texto **dentro** del mensaje, sin distinguir mayúsculas ("mens"
  encuentra "Mensaje"); hasta 100 caracteres. `author_id` filtra por autor.
  Tiene que venir al menos uno; juntos se combinan. `channel_id` acota a un canal.
- Solo busca en los canales de texto donde el usuario tiene `VIEW_CHANNELS`
  (misma regla que el historial). Nunca devuelve mensajes eliminados.
- Responde de la coincidencia más nueva a la más vieja:
  `{ "messages": [...], "next_cursor", "total", "total_capped" }`. Se sigue con
  `?before=<next_cursor>`. `total` viene solo en la primera página, con tope de 1000.
- Sin resultados: `200` con `messages: []`.
- Para abrir un resultado: `GET /v1/channels/:channel_id/messages?around=<id>`.
- Errores: `INVALID_SEARCH_QUERY` / `INVALID_CURSOR` (400), `NOT_SERVER_MEMBER` /
  `FORBIDDEN` (403), `CHANNEL_NOT_FOUND` (404), `SEARCH_UNAVAILABLE` (503).

El término se escapa y se busca con regex (`$text` solo encuentra palabras
enteras). Índices: `messages_channel_user_inserted_at_id` y `channels_server_kind`.

## Mongo con TLS (Atlas)
Si `MONGO_URL` pide TLS (`?ssl=true`, `?tls=true` o `mongodb+srv://`),
`Messaging.MongoOptions` arma el driver con `verify: :verify_peer`, los
certificados raíz del sistema y verificación de hostname. Sin eso, OTP 26
rechaza la conexión (`cacerts: :undefined`). La imagen de Docker instala
`ca-certificates` por esa razón. Con una URL sin TLS (Mongo local) no se agrega nada.

## Cambios mientras estabas desconectado
`missed_messages` trae solo mensajes **nuevos**. Para que un cliente que volvió se entere
también de los mensajes que **cambiaron** (editados y borrados) hay un segundo cursor,
basado en el reloj del servidor:

1. Cada `join` responde `{"server_time": "<ISO 8601 UTC, ms>"}`. El cliente lo guarda
   como cursor. Si además recibió `message_updated` en vivo, puede avanzarlo al
   `edited_at` más nuevo que vio (opcional: solo evita reenvíos).
2. Al reconectar manda en el `join` `{"last_message_id": ..., "changes_since": "<cursor>"}`.
3. El servidor empuja `"changed_messages"` con `{"messages": [...], "deleted_ids": [...]}`:
   en `messages`, los mensajes de ese canal que se editaron desde el cursor, **sin importar
   qué tan viejos sean**, del cambio más viejo al más nuevo, ya con el texto vigente y
   `edited: true`; en `deleted_ids`, los ids de los que se borraron (el cliente los quita de
   su lista; un id que no tenía es inocuo). Un mensaje editado y después borrado aparece solo
   en `deleted_ids`. Va después de
   `missed_messages` y se empuja siempre (aun vacío) cuando se manda `changes_since`, para
   que el cliente sepa que está al día. Un mensaje nuevo que además fue editado aparece en
   los dos: el cliente aplica por `id`, y el último evento gana.
4. Si hubo más de **200** cambios (ediciones y borrados juntos), no se manda una lista parcial: se empuja
   `"resync_required"` y el cliente recarga el historial por REST.

Detalles:
- **Margen de 5 s.** El servidor busca cambios desde `changes_since - 5 s`, para absorber
  diferencias de reloj entre instancias. Por eso un cursor pegado a una edición reciente la
  vuelve a mandar: es inocuo, el cliente aplica por `id`.
- **Compatibilidad.** Sin `changes_since` no hay `changed_messages`: un cliente anterior sigue
  funcionando igual (solo ignora el `server_time` de la respuesta del `join`).
- **Cursor inválido.** Si `changes_since` no es un ISO 8601 válido, el `join` falla con
  `INVALID_CURSOR`.
- **Cómo se guarda.** Cada edición o borrado escribe también `changed_at`, el cursor interno.
  Hay un índice **parcial** `(channel_id, changed_at)` que solo incluye mensajes con
  `changed_at`, así que los mensajes que nunca cambiaron no ocupan lugar en él.
  `Messaging.Chat.IndexSetup` lo crea al arrancar.

## Logs
Los logs son **estructurados**: una línea de JSON por evento, en la salida estándar. Ejemplo (los campos varían según el evento):

```json
{"time":"2026-10-06T19:15:26.860Z","level":"info","service":"messaging","message":"message_sent","channel_id":"…","user_id":"…","message_id":"…"}
```

- **`message`** es el nombre del evento, en inglés y en `snake_case` (`message_sent`, `permissions_client_request_failed`, …). El resto de los campos son datos del evento. Los logs de pedidos HTTP y de sockets/canales **no** son texto de Phoenix: están desactivados (`config :phoenix, :logger, false`) y los reemplaza `Messaging.Log.Telemetry`, que emite eventos con campos propios (ver abajo).
- **Eventos que salen del framework** (todos con campos, ninguno con texto libre):
  - `http_request`: `method`, `route`, `status`, `duration_ms` y `user_id` (quien hizo el pedido, si está autenticado), más el `request_id` que comparten todas las líneas de ese pedido. **`route` es el patrón** (`/v1/blocks/:user_id`), nunca la ruta real: así no se escriben ids ni la query string (donde viaja, por ejemplo, el ticket del WebSocket). Un pedido sin ruta sale como `unmatched`, sin su path. Nivel `info`; `error` si el status es 5xx; `debug` para `/livez` y `/readyz`, que se consultan todo el tiempo.
  - `http_error_rendered` (`error`): una excepción convertida en respuesta de error, con la causa sanitizada.
  - `socket_connected` (`info`, o `warning` si falló): resultado y transporte. Nunca los parámetros (el ticket).
  - `channel_joined` (`info`): `topic`, `user_id` y `result` (`ok` o `error` si se rechazó el acceso).
  - `channel_event` (`debug`): el `event` recibido (`send_dm`, `edit_message`, …) y su duración. Nunca el contenido.
  - `service_started` (`info`): versión y nivel de log con el que arrancó.
- **Acciones trazables.** `message_sent`, `message_edited`, `message_deleted`, `conversation_created`, `block_created` y `block_removed`. Las dos últimas llevan solo el `user_id` de quien actúa: **nunca a quién se bloqueó**, porque esa relación es lo sensible.
- **Nivel configurable** con la variable `LOG_LEVEL` (`debug`, `info`, `warning` o `error`). Por defecto: `info` en producción, `debug` en desarrollo y `warning` en tests. Un valor inválido hace fallar el arranque, con un mensaje claro.
- **Qué significa cada nivel:**
  - `error`: falla que impide ejecutar la funcionalidad (no se pudo guardar un mensaje, no se pudieron consultar los permisos, `catch_up_failed`, …).
  - `warning`: condición anómala que no impide la funcionalidad básica (un aviso en vivo que no se pudo difundir, un evento descartado por inválido, un ticket rechazado, un broker al que hay que reconectarse).
  - `info`: acción iniciada por una persona o por el sistema, trazable (`message_sent`, `message_edited`, `message_deleted`, `conversation_created`, `channel_joined`, `socket_ticket_issued`, eventos aplicados).
  - `debug`: contexto técnico para diagnosticar (por ejemplo `permission_checked`, y las líneas del framework).
- **Qué nunca se escribe.** El contenido de los mensajes, el destinatario de un DM, los tickets, los JWT ni las contraseñas, **en ningún nivel**. Tres capas, para que un error no alcance:
  1. El código solo registra ids y datos técnicos, nunca contenido.
  2. Phoenix solo muestra los parámetros de una lista permitida (`config :phoenix, :filter_parameters, {:keep, [...]}` en `config/config.exs`); todo lo demás sale como `[FILTERED]`. Cubre pedidos REST, eventos del canal y la conexión del socket.
  3. El formateador reemplaza por `[FILTERED]` cualquier campo con un nombre sensible (`content`, `to`, `ticket`, `token`, `raw_jwt`, `authorization`, …).
- **Los motivos de error se sanitizan** (`Messaging.Log.reason/1`): de una excepción solo se escribe su módulo y su causa corta. Antes, un `Jason.DecodeError` incluía el cuerpo completo del mensaje que no se pudo leer.
- **Qué campos se escriben** lo define una lista en `config/config.exs` (`metadata: [...]`). Una clave nueva no aparece en los logs hasta que alguien la agrega a propósito, y Credo avisa si se usa una clave que falta en esa lista.
- **Lo que sigue visible fuera de `messaging`:** el log de acceso de Kong escribe la ruta real de cada pedido (por ejemplo `DELETE /v1/blocks/<id>`, y la query string del WebSocket con el ticket) y la IP del cliente. Ver `planes/logs-y-datos-privados-en-messaging.md`.
- **Reportes de caídas.** Si un proceso se cae, el reporte de Erlang incluye el último mensaje recibido. Phoenix le aplica el mismo filtro de parámetros (sale `"content" => "[FILTERED]"`) y no escribe el estado del proceso, que es donde estaría el JWT. Está cubierto por tests.

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
docker compose up -d mongo rabbitmq postgres
make migrate   # Postgres del outbox (DATABASE_* del .env)
mix phx.server
```

`messaging` ya no llama por HTTP a `servers` ni a `identify-service`: los permisos, las
menciones y la existencia de un usuario se resuelven con una réplica local que se alimenta de
eventos de RabbitMQ (ver "Réplica local de permisos y usuarios"). Para que un servidor o un
usuario creados antes de levantar este servicio aparezcan hay que re-publicar los eventos desde
`servers` e `identify-service` (backfill) con la cola de `messaging` ya creada.

## Tests
```bash
make test   # mix coveralls -- falla si la cobertura total < 70% (coveralls.json)
```
Los tests unitarios y el e2e de `RoomChannel` usan `Mox`
(`Messaging.Chat.RepoMock`, `Messaging.Chat.PermissionsStoreMock`, `Messaging.Chat.MentionResolverMock`) y
`Messaging.Events.LocalBroadcaster` (entrega en tiempo real in-process, sin
broker) -- no necesitan Mongo ni RabbitMQ reales.

Algunos tests de integración sí necesitan infraestructura real y se saltan solos
si no está (mismo patrón que `servers`/`identify-service` con
`DATABASE_HOST`):
```bash
docker compose up -d mongo rabbitmq postgres   # en este repo
export MONGO_URL=mongodb://localhost:27017/messaging_test
export RABBITMQ_URL=amqp://guest:guest@localhost:5672
export DATABASE_HOST=localhost DATABASE_PORT=5435 DATABASE_NAME=discordia_messaging \
  DATABASE_USER=discordia DATABASE_PASSWORD=discordia
mix test
```
- `test/messaging/events/channel_lifecycle_consumer_test.exs`: publica un
  evento real y confirma que la caché de canales en Mongo se actualiza.
- `test/messaging/chat/repo/mongo_test.exs`: paginación hacia atrás y hacia
  adelante contra Mongo real, con mensajes del mismo milisegundo y el índice.
- `test/messaging/events/broadcast_test.exs`: el camino real
  `BroadcastPublisher` -> RabbitMQ -> `BroadcastConsumer` -> PubSub local, con la
  confirmación del broker y la cola durable de cada instancia.
- `test/messaging/outbox/store/postgres_test.exs` (necesita `DATABASE_HOST`): contra un
  Postgres real, el orden de los eventos, que dos pollers no tomen la misma fila
  (`SKIP LOCKED`), que dos eventos del mismo mensaje salgan en orden, el vaciado del contenido al
  publicar, los reintentos y que una instancia que muere deje sus filas pendientes. Crea y
  borra su propio schema (`outbox_test`).

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
│   │   ├── permissions_client.ex # Behaviour de permisos por canal (VIEW / SEND / MANAGE_MESSAGES)
│   │   └── permissions_client/http.ex  # Implementacion real (Req -> servers)
│   ├── chat.ex                   # API publica del context (hace de "Service")
│   ├── presence.ex               # Context: estado de actividad (API publica)
│   ├── presence/
│   │   ├── status.ex             # Regla del estado efectivo y cambios sobre el documento (pura)
│   │   ├── store.ex              # Behaviour de persistencia
│   │   ├── store/mongo.ex        # Implementacion real (findAndModify atomico)
│   │   ├── tracker.ex            # Monitorea los canales user:<id> y escribe el heartbeat de la instancia
│   │   ├── sweeper.ex            # Limpia las conexiones de instancias caidas
│   │   ├── audience.ex           # A que topics avisar (servidores y DM, sin bloqueos)
│   │   └── notifier.ex           # Publica presence_updated / own_status_updated al fanout
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
        ├── room_channel.ex        # Channel de un canal de texto
        ├── user_channel.ex        # Channel personal: DM, menciones y estado de actividad
        └── presence_channel.ex    # Estado de actividad de los miembros de un servidor
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
# Autorización de llamadas privadas

Messaging expone internamente `GET /v1/voice-access/:recipient_id?conversation_id=...`
para que signaling valide que ambos usuarios pertenecen a la conversación
directa y que no existe un bloqueo en ninguno de los dos sentidos. La ruta
requiere el JWT del usuario llamante y no crea ni modifica datos.
