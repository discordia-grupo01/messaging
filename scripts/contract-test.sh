#!/usr/bin/env bash
# Prueba de contrato: levanta messaging contra Postgres, Mongo y RabbitMQ locales y corre
# Schemathesis con openapi.yaml. Sale con 0 solo si no encuentra desvios.
#
# Configuracion por variables de entorno (sin argumentos):
#   APP_PORT               puerto del servicio (18086)
#   DATABASE_HOST/PORT/NAME/USER/PASSWORD  Postgres de prueba; el host debe ser localhost/127.0.0.1
#   MONGO_URL              Mongo de prueba; el host debe ser localhost/127.0.0.1
#   RABBITMQ_URL           RabbitMQ de prueba; el host debe ser localhost/127.0.0.1
#   CONTRACT_APP_MODE      host (mix run, por defecto) o docker (contenedor elixir:1.16)
#   CONTRACT_MAX_EXAMPLES  casos por operacion (50)
#   CONTRACT_SEED          semilla (1)
#   CONTRACT_REPORT_DIR    carpeta del reporte (contract-report)
#   SCHEMATHESIS_BIN       ejecutable de Schemathesis (.contract-venv, o el del PATH)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_PORT="${APP_PORT:-18086}"
DATABASE_HOST="${DATABASE_HOST:-localhost}"
DATABASE_PORT="${DATABASE_PORT:-55506}"
DATABASE_NAME="${DATABASE_NAME:-messaging_contract}"
DATABASE_USER="${DATABASE_USER:-postgres}"
DATABASE_PASSWORD="${DATABASE_PASSWORD:-postgres}"
MONGO_URL="${MONGO_URL:-mongodb://localhost:55526/messaging_contract}"
RABBITMQ_URL="${RABBITMQ_URL:-amqp://guest:guest@localhost:55516}"
CONTRACT_APP_MODE="${CONTRACT_APP_MODE:-host}"
CONTRACT_MAX_EXAMPLES="${CONTRACT_MAX_EXAMPLES:-50}"
CONTRACT_SEED="${CONTRACT_SEED:-1}"
CONTRACT_REPORT_DIR="${CONTRACT_REPORT_DIR:-contract-report}"
CONTRACT_READY_TIMEOUT="${CONTRACT_READY_TIMEOUT:-900}"
APP_CONTAINER="contract-messaging-app"
USER_ID="00000000-0000-4000-8000-0000000000e1"
BASE_URL="http://127.0.0.1:${APP_PORT}"

log() { echo "[contract] $*"; }
die() { echo "[contract] ERROR: $*" >&2; exit 1; }

# Host de una URL (mongodb://u:p@host:1234/db, amqp://...). Vacio si no se puede leer.
url_host() {
  local rest="${1#*://}"
  rest="${rest%%/*}"
  rest="${rest##*@}"
  rest="${rest%%:*}"
  echo "$rest"
}

# Proteccion contra produccion: solo se acepta una base y brokers locales.
guard_host() {
  case "$2" in
    localhost | 127.0.0.1) ;;
    *) die "$1 apunta a '$2': la prueba de contrato solo corre contra localhost/127.0.0.1" ;;
  esac
}

guard_host DATABASE_HOST "$DATABASE_HOST"
guard_host MONGO_URL "$(url_host "$MONGO_URL")"
guard_host RABBITMQ_URL "$(url_host "$RABBITMQ_URL")"
case "$MONGO_URL" in
  mongodb+srv://*) die "MONGO_URL usa mongodb+srv: no es un Mongo local" ;;
esac
case "$CONTRACT_APP_MODE" in host | docker) ;; *) die "CONTRACT_APP_MODE debe ser host o docker" ;; esac

# Schemathesis
if [ -z "${SCHEMATHESIS_BIN:-}" ]; then
  if [ -x ".contract-venv/bin/schemathesis" ]; then
    SCHEMATHESIS_BIN=".contract-venv/bin/schemathesis"
  elif [ -x ".contract-venv/Scripts/schemathesis.exe" ]; then
    SCHEMATHESIS_BIN=".contract-venv/Scripts/schemathesis.exe"
  elif command -v schemathesis > /dev/null 2>&1; then
    SCHEMATHESIS_BIN="schemathesis"
  else
    die "no encuentro schemathesis: python -m venv .contract-venv && .contract-venv/bin/pip install schemathesis==4.33.4"
  fi
fi

# JWT sin firma valida: el servicio solo lee el sub (Messaging.Auth.Token no verifica la firma;
# la valida Kong).
b64url() { base64 | tr -d '=\n' | tr '+/' '-_'; }
TOKEN="$(printf '{"alg":"none","typ":"JWT"}' | b64url).$(printf '{"sub":"%s"}' "$USER_ID" | b64url).contract"

APP_PID=""
cleanup() {
  local status=$?
  if [ -n "$APP_PID" ]; then
    kill "$APP_PID" > /dev/null 2>&1 || true
    wait "$APP_PID" > /dev/null 2>&1 || true
  fi
  if [ "$CONTRACT_APP_MODE" = "docker" ]; then
    docker rm -f "$APP_CONTAINER" > /dev/null 2>&1 || true
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

# Migraciones del outbox sobre la base de prueba (migrate/migrate; el contenedor llega al host por
# host.docker.internal, que en Linux se resuelve con --add-host).
log "aplicando las migraciones en $DATABASE_HOST:$DATABASE_PORT/$DATABASE_NAME"
MSYS_NO_PATHCONV=1 docker run --rm --add-host host.docker.internal:host-gateway \
  -v "$(pwd -W 2> /dev/null || pwd)/migrations:/migrations" migrate/migrate \
  -path=/migrations \
  -database "postgres://${DATABASE_USER}:${DATABASE_PASSWORD}@host.docker.internal:${DATABASE_PORT}/${DATABASE_NAME}?sslmode=disable" \
  up > /dev/null || die "no se pudieron aplicar las migraciones"

# Lo que el servicio recibe: valores de juguete. Sin CLOUDINARY_URL ni SUPABASE_* el almacenamiento
# de adjuntos no tiene backend real, y sin los secretos HMAC no arrancan los consumidores de
# eventos de admin y billing.
APP_ENV=(
  "MIX_ENV=prod"
  "PORT=$APP_PORT"
  "SECRET_KEY_BASE=contract-test-secret-key-base-contract-test-secret-key-base-0123456789abcdef"
  "CHECK_ORIGIN=false"
  "LOG_LEVEL=warning"
  "DATABASE_PORT=$DATABASE_PORT"
  "DATABASE_NAME=$DATABASE_NAME"
  "DATABASE_USER=$DATABASE_USER"
  "DATABASE_PASSWORD=$DATABASE_PASSWORD"
  "DATABASE_SSLMODE=disable"
  "DATABASE_SCHEMA=public"
)
UNSET_ENV=(CLOUDINARY_URL CLOUDINARY_FOLDER CLOUDINARY_API_BASE_URL SUPABASE_URL SUPABASE_SECRET_KEY
  SUPABASE_STORAGE_BUCKET ADMIN_EVENTS_HMAC_SECRET BILLING_EVENTS_HMAC_SECRET
  OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_HEADERS LOG_SHIP_URL LOG_SHIP_API_KEY)

if docker ps -a --format '{{.Names}}' 2> /dev/null | grep -qx "$APP_CONTAINER"; then
  docker rm -f "$APP_CONTAINER" > /dev/null
fi

mkdir -p "$CONTRACT_REPORT_DIR"
APP_LOG="$CONTRACT_REPORT_DIR/app.log"

# Siembra los datos de prueba (canal, miembros, mensajes, conversacion, bloqueo) y despues arranca el
# servicio. Los ids son fijos y los usa schemathesis.toml.
if [ "$CONTRACT_APP_MODE" = "host" ]; then
  log "sembrando los datos de prueba"
  (
    for name in "${UNSET_ENV[@]}"; do unset "$name"; done
    export DATABASE_HOST MONGO_URL RABBITMQ_URL
    for pair in "${APP_ENV[@]}"; do export "$pair"; done
    mix run scripts/contract/seed.exs
  ) > "$CONTRACT_REPORT_DIR/seed.log" 2>&1 || { tail -n 20 "$CONTRACT_REPORT_DIR/seed.log" >&2; die "no se pudo sembrar"; }
  log "arrancando el servicio con mix en el puerto $APP_PORT"
  (
    for name in "${UNSET_ENV[@]}"; do unset "$name"; done
    export DATABASE_HOST MONGO_URL RABBITMQ_URL
    for pair in "${APP_ENV[@]}"; do export "$pair"; done
    exec mix run --no-halt
  ) > "$APP_LOG" 2>&1 &
  APP_PID=$!
else
  # En docker el contenedor llega al host por host.docker.internal; los hosts ya pasaron el guard.
  container_url() { echo "$1" | sed -e 's#@localhost#@host.docker.internal#' -e 's#//localhost#//host.docker.internal#' -e 's#@127.0.0.1#@host.docker.internal#' -e 's#//127.0.0.1#//host.docker.internal#'; }
  docker_env=()
  for pair in "${APP_ENV[@]}"; do docker_env+=(-e "$pair"); done
  docker_env+=(-e "PORT=4000")
  # $1: banderas de docker run, $2: comando mix. El mismo contenedor base siembra y sirve.
  run_elixir() {
    MSYS_NO_PATHCONV=1 docker run $1 \
      --add-host host.docker.internal:host-gateway \
      -v "$(pwd -W 2> /dev/null || pwd):/app" \
      -v contract-messaging-deps:/app/deps \
      -v contract-messaging-build:/app/_build \
      -w /app "${docker_env[@]}" \
      -e "DATABASE_HOST=host.docker.internal" \
      -e "MONGO_URL=$(container_url "$MONGO_URL")" \
      -e "RABBITMQ_URL=$(container_url "$RABBITMQ_URL")" \
      elixir:1.16 sh -c "mix local.hex --force && mix local.rebar --force && mix deps.get && $2"
  }
  log "sembrando los datos de prueba"
  run_elixir "--rm --name contract-messaging-seed" "mix run scripts/contract/seed.exs" \
    > "$CONTRACT_REPORT_DIR/seed.log" 2>&1 || { tail -n 20 "$CONTRACT_REPORT_DIR/seed.log" >&2; die "no se pudo sembrar"; }
  log "arrancando el servicio en el contenedor $APP_CONTAINER (puerto $APP_PORT)"
  run_elixir "-d --name $APP_CONTAINER -p 127.0.0.1:${APP_PORT}:4000" "mix run --no-halt" > /dev/null
fi

app_alive() {
  if [ "$CONTRACT_APP_MODE" = "host" ]; then
    kill -0 "$APP_PID" > /dev/null 2>&1
  else
    [ "$(docker inspect -f '{{.State.Running}}' "$APP_CONTAINER" 2> /dev/null)" = "true" ]
  fi
}

show_app_log() {
  if [ "$CONTRACT_APP_MODE" = "docker" ]; then
    docker logs "$APP_CONTAINER" > "$APP_LOG" 2>&1 || true
  fi
  grep -v '"status":4[0-9][0-9]' "$APP_LOG" | tail -n 15 >&2 || true
}

log "esperando /readyz (hasta ${CONTRACT_READY_TIMEOUT}s; la primera compilacion tarda)"
waited=0
until [ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/readyz" 2> /dev/null || true)" = "200" ]; do
  if ! app_alive; then
    show_app_log
    die "el servicio se cayo antes de quedar listo"
  fi
  if [ "$waited" -ge "$CONTRACT_READY_TIMEOUT" ]; then
    show_app_log
    die "el servicio no quedo listo en ${CONTRACT_READY_TIMEOUT}s"
  fi
  sleep 2
  waited=$((waited + 2))
done
log "servicio listo"

log "corriendo Schemathesis ($CONTRACT_MAX_EXAMPLES casos por operacion, semilla $CONTRACT_SEED)"
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8
# hooks.py fija el usuario a bloquear (POST /v1/blocks) y el servidor y el texto de la busqueda.
export SCHEMATHESIS_HOOKS=hooks
export PYTHONPATH="scripts/contract${PYTHONPATH:+:$PYTHONPATH}"
set +e
# unsupported_method queda afuera: Cowboy responde 501 a TRACE (no el 405 que exige) antes de llegar
# a Phoenix, y con los demas metodos no declarados Phoenix ya responde 404. Ver schemathesis.toml.
"$SCHEMATHESIS_BIN" --config-file scripts/contract/schemathesis.toml run openapi.yaml \
  --url "$BASE_URL" \
  --header "Authorization: Bearer $TOKEN" \
  --exclude-checks unsupported_method \
  --max-examples "$CONTRACT_MAX_EXAMPLES" \
  --seed "$CONTRACT_SEED" \
  --workers 1 \
  --report junit,har --report-dir "$CONTRACT_REPORT_DIR" \
  --no-color
status=$?
set -e

# Cobertura de camino feliz: cada operacion tiene que haber dado al menos un 2xx (salvo las
# justificadas en scripts/contract/coverage.py).
if [ "$status" -eq 0 ]; then
  har="$(ls -t "$CONTRACT_REPORT_DIR"/har-*.json 2> /dev/null | head -n 1)"
  PY="$(dirname "$SCHEMATHESIS_BIN")/python"
  [ -x "$PY" ] || [ -x "$PY.exe" ] || PY="python3"
  "$PY" scripts/contract/coverage.py openapi.yaml "$har" || status=1
fi

if [ "$status" -ne 0 ]; then
  show_app_log
  log "Schemathesis encontro desvios (reporte en $CONTRACT_REPORT_DIR)"
fi
exit "$status"
