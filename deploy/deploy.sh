#!/bin/bash
set -euo pipefail

IMAGE="$1"
PREV_ID=$(docker inspect -f '{{.Image}}' messaging 2>/dev/null || true)

docker pull "$IMAGE"
docker rm -f messaging >/dev/null 2>&1 || true
# Cada WebSocket abierto es un archivo abierto: con el limite por defecto de
# Docker (1024) messaging deja de aceptar conexiones pasados ~1000 usuarios.
docker run -d --name messaging --restart unless-stopped \
  --ulimit nofile=65536:65536 \
  --env-file "$HOME/messaging.env" -p 4000:4000 "$IMAGE" >/dev/null

for _ in $(seq 1 20); do
  if curl -fsS -m 3 http://localhost:4000/readyz >/dev/null 2>&1; then
    echo "deploy OK: $IMAGE"
    exit 0
  fi
  sleep 3
done

echo "ERROR: /readyz no respondio tras el deploy de $IMAGE" >&2
docker logs --tail 30 messaging 2>&1 \
  | sed -E 's#(amqps?://)[^@ ]*@#\1***@#g; s#(mongodb(\+srv)?://)[^@ ]*@#\1***@#g; s#(password=)[^ ]*#\1***#Ig' >&2 || true
docker rm -f messaging >/dev/null 2>&1 || true
if [ -n "$PREV_ID" ]; then
  echo "rollback a la imagen anterior ($PREV_ID)" >&2
  docker run -d --name messaging --restart unless-stopped \
    --ulimit nofile=65536:65536 \
    --env-file "$HOME/messaging.env" -p 4000:4000 "$PREV_ID" >/dev/null
fi
exit 1
