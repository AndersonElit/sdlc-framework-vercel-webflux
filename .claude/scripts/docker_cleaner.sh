#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()     { echo "[$(date '+%H:%M:%S')] $*"; }
log_ok()  { echo "[$(date '+%H:%M:%S')] OK  $*"; }
log_err() { echo "[$(date '+%H:%M:%S')] ERR $*" >&2; }

log "Iniciando limpieza de Docker..."

# Eliminar primero el cluster K3d: si solo se borraran sus contenedores con docker rm,
# k3d quedaría con estado inconsistente (cluster "fantasma"). 'k3d cluster delete --all'
# limpia nodos, load balancer y registries asociados.
delete_k3d() {
  if command -v k3d &>/dev/null; then
    log "Eliminando clusters K3d..."
    k3d cluster delete --all &>/dev/null && log_ok "Clusters K3d eliminados" || log "No había clusters K3d"
    k3d registry delete --all &>/dev/null || true
  fi
}

stop_containers() {
  local ids
  ids=$(docker ps -q)
  if [[ -z "$ids" ]]; then
    log "No hay contenedores corriendo, omitiendo stop."
    return 0
  fi
  log "Deteniendo contenedores..."
  docker stop $ids 2>/dev/null && log_ok "Contenedores detenidos" || log_err "No se pudieron detener algunos contenedores"
}

remove_containers() {
  local ids
  ids=$(docker ps -aq)
  if [[ -z "$ids" ]]; then
    log "No hay contenedores, omitiendo rm."
    return 0
  fi
  log "Eliminando contenedores..."
  docker rm -f $ids 2>/dev/null && log_ok "Contenedores eliminados" || log_err "No se pudieron eliminar algunos contenedores"
}

remove_images() {
  local ids
  ids=$(docker images -aq)
  if [[ -z "$ids" ]]; then
    log "No hay imágenes, omitiendo rmi."
    return 0
  fi
  log "Eliminando imágenes..."
  docker rmi -f $ids 2>/dev/null && log_ok "Imágenes eliminadas" || log_err "No se pudieron eliminar algunas imágenes"
}

remove_volumes() {
  local ids
  ids=$(docker volume ls -q)
  if [[ -z "$ids" ]]; then
    log "No hay volúmenes, omitiendo rm."
    return 0
  fi
  log "Eliminando volúmenes..."
  docker volume rm $ids 2>/dev/null && log_ok "Volúmenes eliminados" || log_err "No se pudieron eliminar algunos volúmenes"
}

purge_networks() {
  log "Purgando redes no utilizadas..."
  docker network prune -f && log_ok "Redes purgadas" || log_err "No se pudieron purgar las redes"
}

failed=()

delete_k3d        || failed+=("delete_k3d")
stop_containers   || failed+=("stop_containers")
remove_containers || failed+=("remove_containers")
remove_images     || failed+=("remove_images")
remove_volumes    || failed+=("remove_volumes")
purge_networks    || failed+=("purge_networks")

echo ""
if [[ ${#failed[@]} -eq 0 ]]; then
  log "Limpieza de Docker completada correctamente."
else
  log_err "Fallaron ${#failed[@]} paso(s): ${failed[*]}"
  exit 1
fi
