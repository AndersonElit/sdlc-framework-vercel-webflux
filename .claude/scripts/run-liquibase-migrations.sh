#!/usr/bin/env bash

# ===========================================================================
# run-liquibase-migrations.sh — Liquibase standalone multi-servicio
#
# Aplica (o inspecciona) los changelogs Liquibase de cada microservicio que
# tenga un directorio db/<servicio>/ en la raíz del repo. No requiere JDK ni
# Liquibase instalados: corre la imagen oficial liquibase/liquibase vía Docker
# con --network host para alcanzar PostgreSQL en localhost.
#
# Prerrequisito: init-databases.sh completado (BDs y usuario de aplicación
#                creados). Docker debe estar activo.
#
# Uso:
#   bash run-liquibase-migrations.sh -P <proyecto> -p <pg-prefix> -u <usuario> -w <clave>
#     [-s <servicio-slug>] [-a update|rollback|status|validate]
#
#   -P, --project    NOMBRE   Slug del proyecto (para logs)                 (obligatorio)
#   -p, --pg-db      PREFIX   Prefijo de BD PostgreSQL (<prefix>_<svc_slug>)(obligatorio)
#   -u, --user       NOMBRE   Usuario de aplicación en PostgreSQL            (obligatorio)
#   -w, --password   CLAVE    Clave del usuario de aplicación                (obligatorio)
#   -s, --service    SLUG     Procesar solo este servicio (ej: clientes-service)
#   -a, --action     ACCION   update (default) | rollback | status | validate
#   -h, --help                Muestra esta ayuda
#
# Qué hace:
#   1. Verifica prerequisitos (docker, terraform)
#   2. Obtiene rds_port desde terraform output
#   3. Descubre directorios db/*-service/ en la raíz del repo
#   4. Por cada servicio (o solo el indicado con -s), ejecuta:
#        docker run liquibase/liquibase <action>
#      montando db/<svc>/changelog/ y db/<svc>/liquibase.properties
#   5. Checklist de criterios de aceptación
# ===========================================================================

set -euo pipefail

log()     { echo "[$(date '+%H:%M:%S')] $*"; }
log_ok()  { echo "[$(date '+%H:%M:%S')] OK  $*"; }
log_err() { echo "[$(date '+%H:%M:%S')] ERR $*" >&2; }
log_warn(){ echo "[$(date '+%H:%M:%S')] WRN $*"; }

BOLD="\033[1m"
RESET="\033[0m"
HEADER() { echo -e "\n${BOLD}━━━ $* ━━━${RESET}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DB_DIR="$REPO_ROOT/db"
TF_DEV_DIR="$REPO_ROOT/terraform/backend/environments/dev"

LIQUIBASE_IMAGE="liquibase/liquibase:latest"

# ──────────────────────────────────────────────────────────────────────────────
# 0. Parámetros
# ──────────────────────────────────────────────────────────────────────────────
PROJECT_NAME=""
PG_DB_NAME=""
APP_USER=""
APP_PASS=""
FILTER_SERVICE=""
ACTION="update"

usage() {
  sed -n '9,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -P|--project)  PROJECT_NAME="$2";    shift 2 ;;
    -p|--pg-db)    PG_DB_NAME="$2";      shift 2 ;;
    -u|--user)     APP_USER="$2";        shift 2 ;;
    -w|--password) APP_PASS="$2";        shift 2 ;;
    -s|--service)  FILTER_SERVICE="$2";  shift 2 ;;
    -a|--action)   ACTION="$2";          shift 2 ;;
    -h|--help)     usage 0 ;;
    *) log_err "Opción desconocida: $1"; usage 1 ;;
  esac
done

MISSING_ARGS=()
[[ -z "$PROJECT_NAME" ]] && MISSING_ARGS+=("-P/--project")
[[ -z "$PG_DB_NAME"   ]] && MISSING_ARGS+=("-p/--pg-db")
[[ -z "$APP_USER"     ]] && MISSING_ARGS+=("-u/--user")
[[ -z "$APP_PASS"     ]] && MISSING_ARGS+=("-w/--password")

if [[ ${#MISSING_ARGS[@]} -gt 0 ]]; then
  log_err "Faltan parámetros obligatorios: ${MISSING_ARGS[*]}"
  usage 1
fi

case "$ACTION" in
  update|rollback|status|validate) ;;
  *) log_err "Acción no soportada: '$ACTION'. Opciones: update, rollback, status, validate"; exit 1 ;;
esac

# ──────────────────────────────────────────────────────────────────────────────
# 1. Verificar prerequisitos
# ──────────────────────────────────────────────────────────────────────────────
HEADER "1. Verificando prerequisitos"

if ! command -v docker &>/dev/null; then
  log_err "docker no está instalado o no está en PATH."
  exit 1
fi
log_ok "docker encontrado ($(docker --version | head -1))."

if ! docker info &>/dev/null; then
  log_err "Docker daemon no está activo. Inicia Docker y reintenta."
  exit 1
fi
log_ok "Docker daemon activo."

if ! command -v terraform &>/dev/null; then
  log_err "terraform no está instalado."
  exit 1
fi
log_ok "terraform encontrado."

if [[ ! -d "$DB_DIR" ]]; then
  log_err "Directorio db/ no encontrado: $DB_DIR"
  log_err "Ejecutar primero: bash .claude/scripts/scaffold-all-services.sh"
  exit 1
fi

# ──────────────────────────────────────────────────────────────────────────────
# 2. Obtener rds_port desde Terraform
# ──────────────────────────────────────────────────────────────────────────────
HEADER "2. Obteniendo puerto PostgreSQL (rds_port)"

if [[ ! -d "$TF_DEV_DIR" ]]; then
  log_err "Directorio Terraform no encontrado: $TF_DEV_DIR"
  log_err "Ejecute primero: bash .claude/scripts/init-dev-environment.sh"
  exit 1
fi

RDS_PORT=$(cd "$TF_DEV_DIR" && terraform output -raw rds_port 2>/dev/null || echo "")

if [[ -z "$RDS_PORT" ]]; then
  log_err "No se pudo obtener rds_port de terraform output."
  exit 1
fi
log_ok "PostgreSQL en localhost:$RDS_PORT"

# ──────────────────────────────────────────────────────────────────────────────
# 3. Descubrir servicios con changelogs Liquibase
# ──────────────────────────────────────────────────────────────────────────────
HEADER "3. Descubriendo servicios con changelogs Liquibase"

mapfile -t ALL_DB_SERVICES < <(find "$DB_DIR" -maxdepth 1 -mindepth 1 -type d -name "*-service" | sort)

if [[ ${#ALL_DB_SERVICES[@]} -eq 0 ]]; then
  log_err "No se encontraron directorios *-service en $DB_DIR"
  log_err "Ejecutar primero: bash .claude/scripts/scaffold-all-services.sh"
  exit 1
fi

if [[ -n "$FILTER_SERVICE" ]]; then
  FILTERED_PATH="$DB_DIR/$FILTER_SERVICE"
  if [[ ! -d "$FILTERED_PATH" ]]; then
    log_err "Servicio no encontrado: $FILTERED_PATH"
    exit 1
  fi
  ALL_DB_SERVICES=("$FILTERED_PATH")
  log_ok "Modo single-service: $FILTER_SERVICE"
else
  log_ok "Servicios descubiertos: ${#ALL_DB_SERVICES[@]}"
  for s in "${ALL_DB_SERVICES[@]}"; do log "  · $(basename "$s")"; done
fi

# ──────────────────────────────────────────────────────────────────────────────
# 4. Ejecutar Liquibase por servicio
# ──────────────────────────────────────────────────────────────────────────────
HEADER "4. Ejecutando Liquibase — acción: $ACTION"

SERVICES_OK=()
SERVICES_FAILED=()

# Convierte nombre de servicio a slug de BD: clientes-service → clientes_service
svc_to_slug() { echo "${1//-/_}"; }

run_liquibase_for_service() {
  local svc_path="$1"
  local svc_name
  svc_name="$(basename "$svc_path")"
  local svc_slug
  svc_slug="$(svc_to_slug "$svc_name")"
  local db_name="${PG_DB_NAME}_${svc_slug}"

  local props_file="$svc_path/liquibase.properties"
  local changelog_dir="$svc_path/changelog"

  if [[ ! -f "$props_file" ]]; then
    log_warn "$svc_name — liquibase.properties no encontrado; omitiendo."
    return 0
  fi

  if [[ ! -d "$changelog_dir" ]]; then
    log_warn "$svc_name — directorio changelog/ no encontrado; omitiendo."
    return 0
  fi

  log "  → $svc_name  [BD: $db_name  puerto: $RDS_PORT]"

  local jdbc_url="jdbc:postgresql://localhost:${RDS_PORT}/${db_name}"

  if docker run --rm \
    --network host \
    -v "$changelog_dir:/liquibase/changelog:ro" \
    -v "$props_file:/liquibase/liquibase.properties:ro" \
    "$LIQUIBASE_IMAGE" \
    --url="$jdbc_url" \
    --username="$APP_USER" \
    --password="$APP_PASS" \
    --changeLogFile="changelog/root.yaml" \
    --log-level=WARNING \
    "$ACTION"; then
    log_ok "  $svc_name — $ACTION completado."
    SERVICES_OK+=("$svc_name")
  else
    log_err "  $svc_name — $ACTION FALLÓ."
    SERVICES_FAILED+=("$svc_name")
  fi
}

for svc_path in "${ALL_DB_SERVICES[@]}"; do
  run_liquibase_for_service "$svc_path"
done

# ──────────────────────────────────────────────────────────────────────────────
# 5. Checklist de criterios de aceptación
# ──────────────────────────────────────────────────────────────────────────────
HEADER "5. Checklist de criterios de aceptación"

PASS="✓"
FAIL="✗"
checklist_ok=0

check_item() {
  local desc="$1" result="$2"
  if [[ "$result" -eq 0 ]]; then
    echo -e "  ${PASS} $desc"
  else
    echo -e "  ${FAIL} $desc"
    checklist_ok=1
  fi
}

check_item "rds_port disponible ($RDS_PORT)" 0

for svc_path in "${ALL_DB_SERVICES[@]}"; do
  svc_name="$(basename "$svc_path")"
  svc_slug="$(svc_to_slug "$svc_name")"
  db_name="${PG_DB_NAME}_${svc_slug}"

  props_ok=0
  [[ -f "$svc_path/liquibase.properties" ]] || props_ok=1
  check_item "$svc_name — liquibase.properties existe" "$props_ok"

  root_ok=0
  [[ -f "$svc_path/changelog/root.yaml" ]] || root_ok=1
  check_item "$svc_name — changelog/root.yaml existe" "$root_ok"

  if [[ "$ACTION" == "update" ]]; then
    RAN_OK=0
    printf '%s\n' "${SERVICES_OK[@]:-}" | grep -qx "$svc_name" || RAN_OK=1
    check_item "$svc_name — update aplicado sin errores" "$RAN_OK"
  fi
done

echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 6. Resumen
# ──────────────────────────────────────────────────────────────────────────────
HEADER "Resumen"

echo ""
printf "  %-40s %s\n" "Acción" "$ACTION"
printf "  %-40s %s\n" "PostgreSQL" "localhost:$RDS_PORT"
printf "  %-40s %s\n" "Servicios procesados" "${#SERVICES_OK[@]} OK  /  ${#SERVICES_FAILED[@]} fallidos"
echo ""

if [[ "${#SERVICES_FAILED[@]}" -gt 0 ]]; then
  log_err "Servicios con errores: ${SERVICES_FAILED[*]}"
fi

if [[ "${#SERVICES_OK[@]}" -gt 0 ]]; then
  for svc in "${SERVICES_OK[@]}"; do
    svc_slug="$(svc_to_slug "$svc")"
    printf "    %-38s %s\n" "· $svc" "(BD: ${PG_DB_NAME}_${svc_slug})"
  done
fi
echo ""

if [[ "$checklist_ok" -eq 0 && "${#SERVICES_FAILED[@]}" -eq 0 ]]; then
  log_ok "Migraciones Liquibase completadas. DATABASECHANGELOG actualizado en cada BD."
else
  log_warn "Algunas migraciones fallaron. Revise los errores arriba."
  exit 1
fi
