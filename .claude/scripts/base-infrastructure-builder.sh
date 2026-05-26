#!/usr/bin/env bash

set -euo pipefail

log() { echo "[$(date '+%H:%M:%S')] $*"; }
log_ok() { echo "[$(date '+%H:%M:%S')] OK  $*"; }
log_err() { echo "[$(date '+%H:%M:%S')] ERR $*" >&2; }

log "Iniciando floci-start..."

log "Verificando dependencias..."
check_cmd() {
  if command -v "$1" &>/dev/null; then
    log_ok "$1 encontrado ($(command -v "$1"))."
  else
    log_err "$1 no está instalado. Abortando."
    exit 1
  fi
}
check_cmd docker
check_cmd terraform

log "Deteniendo contenedores activos..."
if docker ps -aq | grep -q .; then
  docker stop $(docker ps -aq) && log_ok "Contenedores detenidos."
else
  log "No hay contenedores activos."
fi

log "Eliminando contenedores..."
if docker ps -aq | grep -q .; then
  docker rm $(docker ps -aq) && log_ok "Contenedores eliminados."
else
  log "No hay contenedores para eliminar."
fi

log "Eliminando imágenes..."
if docker images -aq | grep -q .; then
  docker rmi $(docker images -aq) && log_ok "Imágenes eliminadas."
else
  log "No hay imágenes para eliminar."
fi

log "Levantando contenedor floci..."
docker run -d \
  --name floci \
  --network floci-net \
  -p 4566:4566 \
  -p 5000-5099:5000-5099 \
  -p 5101-6499:5101-6499 \
  -p 6501-8000:6501-8000 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --add-host=host.docker.internal:host-gateway \
  -e DOCKER_NETWORK=floci-net \
  floci/floci:latest

log_ok "Floci listo."
