# messaging

Servicio de mensajería de Discordia.

## Tabla de contenidos

- [Introducción](#introducción)
- [Pre-requisitos](#pre-requisitos)
- [Cómo correr](#cómo-correr)
- [Variables de entorno](#variables-de-entorno)
- [Comandos Docker](#comandos-docker)
- [Tests](#tests)
- [Más documentación](#más-documentación)

## Introducción

`messaging` es el servicio donde la gente se habla. Se divide en cuatro partes:

- **Mensajes en canales:** enviar, editar y eliminar mensajes con entrega en tiempo real, historial paginado, reconexión sin perder mensajes, reacciones, adjuntos, búsqueda y filtro de palabras prohibidas.
- **Mensajes directos:** conversaciones entre dos usuarios y bloqueo entre ellos.
- **Menciones:** avisar a los usuarios mencionados.
- **Estado de actividad:** quién está conectado, ausente o con un estado propio.

Está hecho en Elixir con Phoenix. Los mensajes viajan por WebSocket y el resto por REST. Guarda los mensajes, las conversaciones y los bloqueos en MongoDB, y en PostgreSQL solo una tabla de salida de eventos (outbox). Antes de guardar un mensaje anota el evento en esa tabla, y recién después lo publica en RabbitMQ: así, si algo falla en el medio, el evento no se pierde.

Puede correr en varias instancias a la vez. RabbitMQ es lo que las conecta: cuando alguien manda un mensaje a una instancia, RabbitMQ se lo reparte a las demás para que lo entreguen a los usuarios que tienen conectados. Por eso RabbitMQ es obligatorio acá, no opcional.

`messaging` no llama a otros servicios por HTTP. Los permisos de cada canal, los roles y la existencia de los usuarios los aprende de los eventos de `servers` e `identify-service` y los guarda en su propia copia.

El JWT lo valida el gateway (Kong) y este servicio solo toma el id del usuario del claim `sub`. No verifica la firma, así que nunca debe quedar expuesto directo a internet.

La API REST está descripta en [`openapi.yaml`](openapi.yaml).

## Pre-requisitos

- **Docker** y **Docker Compose** v2.24 o más nuevo.
- **RabbitMQ**, que se levanta con el repositorio [`rabbit-mq`](https://github.com/discordia-grupo01/rabbit-mq).
- **Elixir 1.16.2** y **Erlang 26.2.1**, solo si querés correr el servicio en tu máquina. El archivo `.tool-versions` los fija, y con [asdf](https://asdf-vm.com/) se instalan con `asdf install`.
- **make**.

## Cómo correr

### Con Docker Compose

Primero levantá RabbitMQ desde el repositorio `rabbit-mq`:

```bash
cd ../rabbit-mq
docker compose up -d
```

Después, en este repositorio, levantá el servicio con sus bases (MongoDB y PostgreSQL):

```bash
docker compose up --build
```

Antes de arrancar el servicio, un contenedor `migrate` crea las tablas de PostgreSQL y termina. Cuando todo esté arriba, comprobá que el servicio esté vivo:

```bash
curl http://localhost:4000/readyz
```

El servicio se conecta a RabbitMQ en `host.docker.internal:5672`, que desde un contenedor es tu máquina. Si lo levantaste en otro lado, completá `RABBITMQ_URL_DOCKER` en el `.env`.

Si querés cambiar puertos, usuario de la base o los secretos de prueba, copiá el archivo de ejemplo y editalo antes de levantar:

```bash
cp .env.example .env
```

Este compose levanta solo lo que es de este servicio. Para el sistema completo (con el gateway y los demás servicios) usá el compose del repositorio `infrastructure`.

### Para desarrollar

Si vas a tocar el código, te conviene correr el servicio en tu máquina (con recarga en caliente) y dejar en contenedores solo las bases:

```bash
cp .env.example .env
asdf install
mix local.hex --force && mix local.rebar --force
mix deps.get
docker compose up -d mongo postgres
make migrate
mix phx.server
```

Con el `.env` de ejemplo, el servicio se conecta a las bases que acabás de levantar y a RabbitMQ en `localhost`.

## Variables de entorno

Se leen del entorno o de un archivo `.env`. El archivo [`.env.example`](.env.example) trae valores listos para correr en local.

| Variable | Default | Descripción |
|---|---|---|
| `SECRET_KEY_BASE` | obligatoria | Secreto de Phoenix. Se genera con `mix phx.gen.secret`. |
| `PORT` | `4000` | Puerto donde escucha el servicio. |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warning` o `error`. |
| `MONGO_URL` | `mongodb://localhost:27017/messaging_dev` | Conexión a MongoDB. En producción, Atlas con TLS. |
| `MONGO_POOL_SIZE` | `10` | Conexiones a Mongo por instancia. |
| `RABBITMQ_URL` | `amqp://guest:guest@localhost:5672` | Conexión a RabbitMQ. Obligatoria. |
| `DATABASE_HOST` | `localhost` | Host de PostgreSQL (el outbox). |
| `DATABASE_PORT` | `5432` | Puerto de PostgreSQL. El `.env.example` usa `5435`, el del compose. |
| `DATABASE_NAME` | `messaging` | Nombre de la base. |
| `DATABASE_USER` | `postgres` | Usuario de la base. |
| `DATABASE_PASSWORD` | `postgres` | Contraseña de la base. |
| `DATABASE_SSLMODE` | `disable` | `disable` en local, `require` con Supabase. |
| `DATABASE_SCHEMA` | `public` | Schema del outbox. En Supabase es `messaging`. |
| `DATABASE_POOL_SIZE` | `5` | Conexiones a PostgreSQL por instancia. |
| `ADMIN_EVENTS_HMAC_SECRET` | vacío | Secreto compartido con `admin` para verificar las suspensiones. Vacío = ese consumidor no arranca. |
| `BILLING_EVENTS_HMAC_SECRET` | vacío | Secreto compartido con `billing` para verificar el estado de Premium. Vacío = ese consumidor no arranca. |
| `PRESENCE_IDLE_MS` | `300000` | Inactividad tras la que un usuario figura como ausente. |
| `PRESENCE_INSTANCE_HEARTBEAT_MS` | `10000` | Cada cuánto avisa una instancia que sigue viva. |
| `PRESENCE_INSTANCE_STALE_MS` | `30000` | Cuánto sin avisar para dar por caída a una instancia. |
| `CLOUDINARY_URL` | vacío | Credenciales de Cloudinary para los adjuntos chicos. Es un secreto. Vacío = sin adjuntos. |
| `CLOUDINARY_FOLDER` | `discordia/attachments` | Carpeta de Cloudinary. |
| `SUPABASE_URL` | vacío | URL del proyecto de Supabase, para los adjuntos grandes (Premium). |
| `SUPABASE_SECRET_KEY` | vacío | Clave del proyecto. Es un secreto. |
| `SUPABASE_STORAGE_BUCKET` | `attachments` | Bucket de Supabase Storage. |
| `CHECK_ORIGIN` | los dominios de la web | Orígenes permitidos para el WebSocket, separados por coma. Solo en producción. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | vacío | Backend OpenTelemetry (por ejemplo New Relic). Vacío = sin trazas ni métricas. |
| `OTEL_EXPORTER_OTLP_HEADERS` | vacío | Credenciales del backend. Es un secreto. |
| `LOG_SHIP_URL` | vacío | Si se completa, también manda los logs a New Relic. |

Variables que usa solo `docker-compose.yml`:

| Variable | Default | Descripción |
|---|---|---|
| `API_PORT` | `4000` | Puerto del servicio en tu máquina. |
| `DATABASE_PORT` | `5435` | Puerto de PostgreSQL en tu máquina. |
| `MONGO_PORT` | `27017` | Puerto de MongoDB en tu máquina. |
| `RABBITMQ_URL_DOCKER` | `amqp://guest:guest@host.docker.internal:5672` | Conexión a RabbitMQ para el servicio que corre dentro del compose. |

## Comandos Docker

Todos desde la raíz del repositorio.

| Qué querés hacer | Comando |
|---|---|
| Levantar todo | `docker compose up --build` |
| Levantar todo en segundo plano | `docker compose up -d --build` |
| Levantar solo las bases | `docker compose up -d mongo postgres` |
| Ver los logs del servicio | `docker compose logs -f api` |
| Ver qué está corriendo | `docker compose ps` |
| Reconstruir solo el servicio | `docker compose up -d --build api` |
| Abrir una consola de PostgreSQL | `docker compose exec postgres psql -U discordia -d discordia_messaging` |
| Abrir una consola de MongoDB | `docker compose exec mongo mongosh messaging_dev` |
| Bajar todo, conservando los datos | `docker compose down` |
| Bajar todo y borrar los datos | `docker compose down -v` |

Las migraciones nuevas se aplican solas cada vez que levantás el compose.

Para construir y correr la imagen a mano:

```bash
docker build -t messaging .
docker run --rm -p 4000:4000 --env-file .env messaging
```

Dentro de un contenedor, `MONGO_URL`, `DATABASE_HOST` y `RABBITMQ_URL` no pueden apuntar a `localhost`: tienen que usar el nombre del contenedor o `host.docker.internal`.

## Tests

Los tests unitarios no necesitan nada más:

```bash
make test
```

Usan dobles (Mox) para la base y la entrega en vivo, así que no necesitan MongoDB ni RabbitMQ. El comando falla si la cobertura total baja del 70 %.

Algunos tests de integración sí usan infraestructura real y se saltean solos si no la encuentran. Levantá las bases, con RabbitMQ desde el repositorio `rabbit-mq`:

```bash
docker compose up -d mongo postgres

MONGO_URL=mongodb://localhost:27017/messaging_test \
RABBITMQ_URL=amqp://guest:guest@localhost:5672 \
DATABASE_HOST=localhost DATABASE_PORT=5435 DATABASE_NAME=discordia_messaging \
DATABASE_USER=discordia DATABASE_PASSWORD=discordia \
mix test
```

Cubren que la caché de canales se actualice con un evento real, la paginación del historial contra MongoDB, el camino completo de la difusión entre instancias por RabbitMQ, y el outbox contra PostgreSQL (orden de los eventos, que dos procesos no tomen la misma fila y los reintentos).

El código se revisa con `make format`, `make lint` y `make dialyzer`. `make ci` corre lo mismo que el CI. Activá el hook de formato una vez por clon:

```bash
git config core.hooksPath .githooks
```

## Más documentación

En este repositorio:

- [`docs/historias-de-usuario.md`](docs/historias-de-usuario.md): las historias del catálogo que resuelve este servicio.
- [`openapi.yaml`](openapi.yaml): contrato de la API REST. Se genera con `make openapi`, no se edita a mano.

En el repositorio [`docs`](https://github.com/discordia-grupo01/docs):

- [`asyncapi`](https://github.com/discordia-grupo01/docs/tree/main/asyncapi): los eventos que este servicio publica y consume.
