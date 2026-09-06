# discordia-servicio (Elixir)

Servicio de <Epica> de Discordia. Cubre las historias: <lista>.

## Stack
- Lenguaje: Elixir
- Framework: Phoenix (Channels)
- BDD: MongoDB
- Libs: joken (JWT), amqp o gnat (event bus), mongodb_driver

## Setup local
```bash
cp .env.example .env
mix local.hex --force && mix local.rebar --force
mix deps.get
docker compose up -d mongo
mix phx.server
```

## Tests
```bash
mix test --cover
```

## Endpoints / Channels
- WS /socket - ver lib/discordia_servicio_web/channels/
- GET /livez
- GET /readyz

## Eventos que publica
- <evento>

## Eventos que consume
- <evento>

## Formateo automatico
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

## Arquitectura del proyecto

Phoenix organiza el codigo por **Context** (dominio de negocio), no por capa
tecnica como Spring Boot. No existe una carpeta `services/` ni `controllers/`
global para todo el proyecto.

```
lib/
├── my_app/                      # Logica de negocio pura, sin HTTP
│   ├── application.ex           # Arranca el supervisor de la app
│   └── my_context/              # Un Context = un area de negocio
│       ├── my_context.ex        # API publica del context (hace de "Service")
│       └── my_entity.ex         # Struct de una entidad (hace de "Entity")
│
└── my_app_web/                  # Capa web (HTTP y websockets)
    ├── endpoint.ex               # El servidor en si
    ├── router.ex                 # Mapea rutas -> controllers
    ├── controllers/
    │   ├── health_controller.ex
    │   └── my_entity_controller.ex
    └── channels/
        ├── user_socket.ex        # Punto de entrada de websockets
        └── my_entity_channel.ex  # Channel de ejemplo
```

### Equivalencia con Spring Boot

| Spring Boot | Phoenix | Diferencia clave |
|---|---|---|
| `@RestController` | `my_app_web/controllers/*.ex` | Igual de simple: recibe request, delega, responde |
| `@Service` | `my_app/<context>/<context>.ex` | En Spring es una clase; en Phoenix es un modulo con funciones publicas dentro de SU carpeta de dominio |
| `@Entity` | `my_app/<context>/<entidad>.ex` | Con Ecto es un `schema`; sin Ecto (Mongo) es un struct comun |
| `@Repository` / `JpaRepository` | `Repo` (Ecto o wrapper propio de Mongo) | Con Mongo lo escriben ustedes, no hay auto-repository |
| Paquete por capa | Carpeta por Context | NO hay una carpeta `services/` global |

### Regla de oro

El controller/channel (capa web) **nunca** accede directo a la entidad ni a la
base de datos. Siempre entra por la API publica del Context:
`MyApp.MyContext.<accion>(...)`.

## Setup local
```bash
cp .env.example .env
mix local.hex --force && mix local.rebar --force
mix deps.get
docker compose up -d mongo
mix phx.server
```

## Formateo automatico
```bash
git config core.hooksPath .githooks
```

## CI local
```bash
make ci
```

## Endpoints
- `GET /livez`, `GET /readyz`
- `GET /my_entities`, `POST /my_entities` (ejemplo de context expuesto por REST)
- WS `/socket`, channel `my_entity:*`
