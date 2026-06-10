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

log "Compilando ${#services[@]} servicio(s) en $BACKEND_DIR"

failed=()

for svc_path in "${services[@]}"; do
  svc_name="$(basename "$svc_path")"
  if [[ -f "$svc_path/build.sbt" ]]; then
    log "Compilando $svc_name (sbt)..."
    if (cd "$svc_path" && sbt --error compile 2>&1); then
      log_ok "$svc_name"
    else
      log_err "$svc_name: falló sbt compile"
      failed+=("$svc_name")
    fi
  elif [[ -f "$svc_path/pom.xml" ]]; then
    log "Compilando $svc_name..."
    if (cd "$svc_path" && mvn compile -q); then
      log_ok "$svc_name"
    else
      log_err "$svc_name: falló mvn compile"
      failed+=("$svc_name")
    fi
  else
    log_err "$svc_name: ni pom.xml ni build.sbt encontrado, omitiendo"
    failed+=("$svc_name")
  fi
done

echo ""
if [[ ${#failed[@]} -eq 0 ]]; then
  log "Todos los servicios compilaron correctamente."
else
  log_err "Fallaron ${#failed[@]} servicio(s): ${failed[*]}"
  exit 1
fi
