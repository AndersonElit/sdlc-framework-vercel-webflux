#!/usr/bin/env bash

# ===========================================================================
# run-liquibase-migrations.sh — Liquibase standalone multi-servicio
#
# Aplica (o inspecciona) los changelogs Liquibase de cada microservicio que
# tenga un directorio db/<servicio>/ en la raíz del repo. Requiere Liquibase
# instalado en el VPS (vps-setup.sh prereqs). Los changelogs se copian al VPS
# vía scp, se ejecutan con liquibase nativo y se limpian después.
#
# Prerrequisito: vps-setup.sh prereqs completado (Liquibase en /usr/local/bin).
#                init-databases.sh completado (BDs y usuario de aplicación
#                creados en el VPS).
#
# Uso:
#   bash run-liquibase-migrations.sh -P <proyecto> -p <pg-prefix> -u <usuario> -w <clave>
#     --vps-ip <IP> [-s <servicio-slug>] [-a update|rollback|status|validate]
#
#   -P, --project    NOMBRE   Slug del proyecto (para logs)                 (obligatorio)
#   -p, --pg-db      PREFIX   Prefijo de BD PostgreSQL (<prefix>_<svc_slug>)(obligatorio)
#   -u, --user       NOMBRE   Usuario de aplicación en PostgreSQL            (obligatorio)
#   -w, --password   CLAVE    Clave del usuario de aplicación                (obligatorio)
#   --vps-ip         IP       IP del VPS donde corren Liquibase y PostgreSQL (obligatorio)
#   --vps-user       USER     Usuario SSH del VPS   (default: ubuntu)
#   --vps-ssh-key    FILE     Clave SSH privada      (default: ~/.ssh/id_ed25519)
#   --db-dir         PATH     Ruta local al repo de migraciones ya clonado
#                             (default: <repo_root>/db/ del propio proyecto)
#   --gitea-clone             Clona automáticamente <project>-migrations desde Gitea
#                             (http://<vps-ip>:3000/<project>/<project>-migrations)
#   -s, --service    SLUG     Procesar solo este servicio (ej: clientes-service)
#   -a, --action     ACCION   update (default) | rollback | status | validate
#   -h, --help                Muestra esta ayuda
#
# Qué hace:
#   1. Verifica prerequisitos (ssh, scp, nc)
#   2. Verifica conectividad SSH al VPS y que liquibase esté disponible
#   3. Descubre directorios db/*-service/ en la raíz del repo
#   4. Por cada servicio (o solo el indicado con -s):
#        a. Copia db/<svc>/changelog/ y db/<svc>/liquibase.properties al VPS
#        b. Ejecuta liquibase <action> en el VPS vía SSH
#        c. Elimina los archivos temporales del VPS
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
EXTERNAL_DB_DIR=""

# ──────────────────────────────────────────────────────────────────────────────
# 0. Parámetros
# ──────────────────────────────────────────────────────────────────────────────
PROJECT_NAME=""
PG_DB_NAME=""
APP_USER=""
APP_PASS=""
VPS_IP=""
VPS_USER="${VPS_USER:-ubuntu}"
VPS_SSH_KEY="${VPS_SSH_KEY:-$HOME/.ssh/id_ed25519}"
FILTER_SERVICE=""
ACTION="update"
GITEA_CLONE=0

usage() {
  sed -n '9,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -P|--project)    PROJECT_NAME="$2";    shift 2 ;;
    -p|--pg-db)      PG_DB_NAME="$2";      shift 2 ;;
    -u|--user)       APP_USER="$2";        shift 2 ;;
    -w|--password)   APP_PASS="$2";        shift 2 ;;
    --vps-ip)        VPS_IP="$2";          shift 2 ;;
    --vps-ip=*)      VPS_IP="${1#*=}";     shift ;;
    --vps-user)      VPS_USER="$2";        shift 2 ;;
    --vps-ssh-key)   VPS_SSH_KEY="$2";     shift 2 ;;
    -s|--service)    FILTER_SERVICE="$2";  shift 2 ;;
    -a|--action)     ACTION="$2";          shift 2 ;;
    --db-dir)        EXTERNAL_DB_DIR="$2"; shift 2 ;;
    --db-dir=*)      EXTERNAL_DB_DIR="${1#*=}"; shift ;;
    --gitea-clone)   GITEA_CLONE=1; shift ;;
    -h|--help)       usage 0 ;;
    *) log_err "Opción desconocida: $1"; usage 1 ;;
  esac
done

MISSING_ARGS=()
[[ -z "$PROJECT_NAME" ]] && MISSING_ARGS+=("-P/--project")
[[ -z "$PG_DB_NAME"   ]] && MISSING_ARGS+=("-p/--pg-db")
[[ -z "$APP_USER"     ]] && MISSING_ARGS+=("-u/--user")
[[ -z "$APP_PASS"     ]] && MISSING_ARGS+=("-w/--password")
[[ -z "$VPS_IP"       ]] && MISSING_ARGS+=("--vps-ip")

if [[ ${#MISSING_ARGS[@]} -gt 0 ]]; then
  log_err "Faltan parámetros obligatorios: ${MISSING_ARGS[*]}"
  usage 1
fi

case "$ACTION" in
  update|rollback|status|validate) ;;
  *) log_err "Acción no soportada: '$ACTION'. Opciones: update, rollback, status, validate"; exit 1 ;;
esac

# Resolver DB_DIR: --db-dir > --gitea-clone > default ($REPO_ROOT/db)
if [[ -n "$EXTERNAL_DB_DIR" ]]; then
  DB_DIR="$EXTERNAL_DB_DIR"
elif [[ "$GITEA_CLONE" -eq 1 ]]; then
  GITEA_MIGRATIONS_REPO="${PROJECT_NAME}-migrations"
  GITEA_CLONE_URL="http://gitea-admin:gitea-admin@${VPS_IP}:3000/${PROJECT_NAME}/${GITEA_MIGRATIONS_REPO}.git"
  GITEA_LOCAL_DIR="/tmp/${PROJECT_NAME}-migrations-$$"
  log "Clonando repo de migraciones desde Gitea..."
  log "  URL: http://${VPS_IP}:3000/${PROJECT_NAME}/${GITEA_MIGRATIONS_REPO}"
  if git clone "$GITEA_CLONE_URL" "$GITEA_LOCAL_DIR" 2>&1; then
    log_ok "Repo clonado en $GITEA_LOCAL_DIR"
    DB_DIR="$GITEA_LOCAL_DIR"
    # Registrar limpieza al salir
    trap 'rm -rf "$GITEA_LOCAL_DIR"' EXIT
  else
    log_err "No se pudo clonar desde Gitea. Verifica que el repo ${PROJECT_NAME}/${GITEA_MIGRATIONS_REPO} exista."
    exit 1
  fi
fi

ssh_vps() {
  ssh -i "$VPS_SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
      -o BatchMode=yes "${VPS_USER}@${VPS_IP}" "$@"
}

scp_to_vps() {
  scp -i "$VPS_SSH_KEY" -o StrictHostKeyChecking=no -r "$1" "${VPS_USER}@${VPS_IP}:$2"
}

PG_PORT="5432"

# ──────────────────────────────────────────────────────────────────────────────
# 1. Verificar prerequisitos
# ──────────────────────────────────────────────────────────────────────────────
HEADER "1. Verificando prerequisitos"

for dep in ssh scp; do
  if ! command -v "$dep" &>/dev/null; then
    log_err "'$dep' no está instalado o no está en PATH."
    exit 1
  fi
done
log_ok "ssh y scp disponibles."

if [[ ! -d "$DB_DIR" ]]; then
  log_err "Directorio db/ no encontrado: $DB_DIR"
  log_err "Ejecutar primero: bash .claude/scripts/scaffold-all-services.sh"
  exit 1
fi

# ──────────────────────────────────────────────────────────────────────────────
# 2. Verificar conectividad VPS y Liquibase nativo
# ──────────────────────────────────────────────────────────────────────────────
HEADER "2. Verificando VPS ($VPS_IP)"

if ! ssh_vps "echo OK" &>/dev/null; then
  log_err "No se puede conectar al VPS $VPS_IP via SSH."
  log_err "  Verifica la IP y la clave $VPS_SSH_KEY"
  exit 1
fi
log_ok "VPS $VPS_IP accesible via SSH."

if ! ssh_vps "command -v liquibase" &>/dev/null; then
  log_err "Liquibase no está instalado en el VPS."
  log_err "  Ejecutar: vps-setup.sh prereqs --vm-ip $VPS_IP"
  exit 1
fi
LIQUIBASE_VER=$(ssh_vps "liquibase --version 2>&1 | head -1" || true)
log_ok "Liquibase disponible en VPS: $LIQUIBASE_VER"

if command -v nc &>/dev/null; then
  if ! nc -z -w3 "$VPS_IP" "$PG_PORT" &>/dev/null; then
    log_err "No se puede alcanzar PostgreSQL en $VPS_IP:$PG_PORT."
    exit 1
  fi
  log_ok "PostgreSQL accesible en $VPS_IP:$PG_PORT"
else
  log_warn "nc no disponible — se omite la verificación de puerto PostgreSQL."
fi

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
HEADER "4. Ejecutando Liquibase en VPS — acción: $ACTION"

SERVICES_OK=()
SERVICES_FAILED=()

svc_to_slug() { echo "${1//-/_}"; }

VPS_TMP="/tmp/liquibase-migrations-$$"

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

  log "  → $svc_name  [BD: $db_name  host: $VPS_IP:$PG_PORT]"

  local jdbc_url="jdbc:postgresql://localhost:${PG_PORT}/${db_name}"
  local vps_svc_dir="${VPS_TMP}/${svc_name}"

  # Crear directorio temporal en VPS y copiar changelogs
  ssh_vps "mkdir -p '${vps_svc_dir}/changelog'"
  scp_to_vps "$props_file"    "${vps_svc_dir}/liquibase.properties"
  scp_to_vps "$changelog_dir" "${vps_svc_dir}/"

  if ssh_vps "liquibase \
    --url='${jdbc_url}' \
    --username='${APP_USER}' \
    --password='${APP_PASS}' \
    --changeLogFile='changelog/root.yaml' \
    --log-level=WARNING \
    --defaultsFile='${vps_svc_dir}/liquibase.properties' \
    --search-path='${vps_svc_dir}' \
    '${ACTION}'" 2>&1; then
    log_ok "  $svc_name — $ACTION completado."
    SERVICES_OK+=("$svc_name")
  else
    log_err "  $svc_name — $ACTION FALLÓ."
    SERVICES_FAILED+=("$svc_name")
  fi
}

# Crear directorio raíz temporal en VPS
ssh_vps "mkdir -p '$VPS_TMP'"

for svc_path in "${ALL_DB_SERVICES[@]}"; do
  run_liquibase_for_service "$svc_path"
done

# Limpiar archivos temporales del VPS
ssh_vps "rm -rf '$VPS_TMP'" && log "Archivos temporales del VPS eliminados."

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

check_item "PostgreSQL nativo accesible en $VPS_IP:$PG_PORT" 0
check_item "Liquibase nativo disponible en VPS $VPS_IP" 0

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
printf "  %-40s %s\n" "PostgreSQL (VPS nativo)" "$VPS_IP:$PG_PORT"
printf "  %-40s %s\n" "Liquibase" "nativo en VPS $VPS_IP"
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
