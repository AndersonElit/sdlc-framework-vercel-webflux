#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BACKEND_DIR="${1:-$REPO_ROOT/backend}"

log()     { echo "[$(date '+%H:%M:%S')] $*"; }
log_ok()  { echo "[$(date '+%H:%M:%S')] OK  $*"; }
log_err() { echo "[$(date '+%H:%M:%S')] ERR $*" >&2; }

if [[ ! -d "$BACKEND_DIR" ]]; then
  log_err "Directorio no encontrado: $BACKEND_DIR"
  exit 1
fi

mapfile -t services < <(find "$BACKEND_DIR" -maxdepth 1 -mindepth 1 -type d -name "*-service" | sort)

if [[ ${#services[@]} -eq 0 ]]; then
  log_err "No se encontraron directorios *-service en $BACKEND_DIR"
  exit 1
fi

log "Creando secrets para ${#services[@]} servicio(s) en $BACKEND_DIR"

failed=()

for svc_path in "${services[@]}"; do
  svc_name="$(basename "$svc_path")"
  script="$svc_path/scripts/create-secrets-dev.sh"
  if [[ ! -f "$script" ]]; then
    log_err "$svc_name: create-secrets-dev.sh no encontrado, omitiendo"
    failed+=("$svc_name")
    continue
  fi
  log "Creando secrets: $svc_name"
  if bash "$script"; then
    log_ok "$svc_name"
  else
    log_err "$svc_name: falló create-secrets-dev.sh"
    failed+=("$svc_name")
  fi
done

echo ""
if [[ ${#failed[@]} -eq 0 ]]; then
  log "Secrets creados correctamente para todos los servicios."
else
  log_err "Fallaron ${#failed[@]} servicio(s): ${failed[*]}"
  exit 1
fi
