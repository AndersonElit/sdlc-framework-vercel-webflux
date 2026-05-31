#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FRONTEND_DIR="${1:-$REPO_ROOT/frontend}"

log()     { echo "[$(date '+%H:%M:%S')] $*"; }
log_ok()  { echo "[$(date '+%H:%M:%S')] OK  $*"; }
log_err() { echo "[$(date '+%H:%M:%S')] ERR $*" >&2; }

if [[ ! -d "$FRONTEND_DIR" ]]; then
  log_err "Directorio no encontrado: $FRONTEND_DIR"
  exit 1
fi

mapfile -t projects < <(find "$FRONTEND_DIR" -maxdepth 1 -mindepth 1 -type d | sort)

if [[ ${#projects[@]} -eq 0 ]]; then
  log_err "No se encontraron proyectos en $FRONTEND_DIR"
  exit 1
fi

log "Verificando ${#projects[@]} proyecto(s) frontend en $FRONTEND_DIR"

failed=()

run_step() {
  local name="$1" cmd="$2" dir="$3"
  log "[$name] $cmd"
  if (cd "$dir" && eval "$cmd"); then
    log_ok "[$name] $cmd"
  else
    log_err "[$name] falló: $cmd"
    failed+=("$name: $cmd")
    return 1
  fi
}

for proj_path in "${projects[@]}"; do
  proj_name="$(basename "$proj_path")"

  if [[ ! -f "$proj_path/package.json" ]]; then
    log_err "$proj_name: package.json no encontrado, omitiendo"
    failed+=("$proj_name: sin package.json")
    continue
  fi

  log "--- $proj_name ---"

  run_step "$proj_name" "npm install" "$proj_path" || continue

  pkg="$proj_path/package.json"
  has_script() { grep -q "\"$1\"" "$pkg"; }

  has_script "type-check" && run_step "$proj_name" "npm run type-check" "$proj_path"
  has_script "lint"        && run_step "$proj_name" "npm run lint"       "$proj_path"
done

echo ""
if [[ ${#failed[@]} -eq 0 ]]; then
  log "Todos los proyectos frontend verificados correctamente."
else
  log_err "Fallaron ${#failed[@]} paso(s):"
  for f in "${failed[@]}"; do log_err "  - $f"; done
  exit 1
fi
