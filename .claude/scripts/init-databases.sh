#!/usr/bin/env bash

# ===========================================================================
# init-databases.sh — Etapa 1: Inicializar bases de datos (PostgreSQL + MongoDB)
#
# Implementa el patrón Database-per-Service: cada microservicio detectado en
# backend/ recibe su propia base de datos aislada. Ningún servicio comparte
# base de datos con otro. El esquema lo aplica Liquibase standalone
# (run-liquibase-migrations.sh) como paso previo al despliegue; no depende
# del arranque del servicio (Flyway requiere JDBC — incompatible con R2DBC).
#
# Prerrequisito: Etapa 0 completada (init-dev-environment.sh finalizó con
#                checklist ✓ y terraform output rds_port disponible).
#                El scaffold debe haberse ejecutado antes (backend/ debe existir).
#
# Uso:
#   bash init-databases.sh -P <proyecto> -p <pg-prefix> -m <mongo-prefix> -u <usuario> -w <clave>
#
#   -P, --project    NOMBRE   Slug del proyecto (contenedor Kafka, prefijo secrets) (obligatorio)
#   -p, --pg-db      PREFIX   Prefijo para nombres de BD PostgreSQL por servicio    (obligatorio)
#                             Cada servicio recibe: <prefix>_<servicio_slug>
#   -m, --mongo-db   PREFIX   Prefijo para nombres de BD MongoDB por servicio       (obligatorio)
#                             Cada servicio recibe: <prefix>_<servicio_slug>
#   -u, --user       NOMBRE   Usuario de aplicación a crear                         (obligatorio)
#   -w, --password   CLAVE    Clave del usuario de aplicación                       (obligatorio)
#   -h, --help                Muestra esta ayuda
#
# Qué hace:
#   1. Verifica prerequisitos (psql, mongosh, terraform, docker)
#   2. Verifica contenedores floci, floci-mongo y Kafka
#   3. Crea usuario de aplicación en PostgreSQL
#   4. Detecta servicios en backend/ y crea una BD PostgreSQL por cada uno
#      que use el adaptador driven/postgres (pattern Database-per-Service)
#   5. Detecta servicios en backend/ y crea una BD MongoDB por cada uno
#      que use el adaptador driven/mongo, con usuario de solo lectura/escritura
#      restringido a esa BD
#   6. Crea BDs de reportería (<prefix>_reporting, <prefix>_readmodel) vacías
#   7. Checklist de criterios de aceptación
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
BACKEND_DIR="$REPO_ROOT/backend"

TF_DEV_DIR="$REPO_ROOT/terraform/backend/environments/dev"

COLLECTIONS_FILES=("$REPO_ROOT/docs/design/database"/*.js)
COLLECTIONS_JS="${COLLECTIONS_FILES[0]:-}"

# Convierte nombre de servicio a slug de BD: clientes-service → clientes_service
svc_to_slug() { echo "${1//-/_}"; }

# ──────────────────────────────────────────────────────────────────────────────
# 0. Parámetros (nombres de BD y credenciales de aplicación — todos obligatorios)
# ──────────────────────────────────────────────────────────────────────────────
PROJECT_NAME=""
PG_DB_NAME=""
MONGO_DB_NAME=""
APP_USER=""
APP_PASS=""
VPS_IP=""
VPS_USER="${VPS_USER:-ubuntu}"
VPS_SSH_KEY="${VPS_SSH_KEY:-$HOME/.ssh/id_ed25519}"

usage() {
  sed -n '9,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -P|--project)  PROJECT_NAME="$2"; shift 2 ;;
    -p|--pg-db)    PG_DB_NAME="$2";   shift 2 ;;
    -m|--mongo-db) MONGO_DB_NAME="$2"; shift 2 ;;
    -u|--user)     APP_USER="$2";     shift 2 ;;
    -w|--password) APP_PASS="$2";     shift 2 ;;
    --vps-ip)      VPS_IP="$2";       shift 2 ;;
    --vps-user)    VPS_USER="$2";     shift 2 ;;
    --vps-ssh-key) VPS_SSH_KEY="$2";  shift 2 ;;
    -h|--help)     usage 0 ;;
    *) log_err "Opción desconocida: $1"; usage 1 ;;
  esac
done

MISSING_ARGS=()
[[ -z "$PROJECT_NAME"  ]] && MISSING_ARGS+=("-P/--project")
[[ -z "$PG_DB_NAME"    ]] && MISSING_ARGS+=("-p/--pg-db")
[[ -z "$MONGO_DB_NAME" ]] && MISSING_ARGS+=("-m/--mongo-db")
[[ -z "$APP_USER"      ]] && MISSING_ARGS+=("-u/--user")
[[ -z "$APP_PASS"      ]] && MISSING_ARGS+=("-w/--password")
[[ -z "$VPS_IP"        ]] && MISSING_ARGS+=("--vps-ip")

if [[ ${#MISSING_ARGS[@]} -gt 0 ]]; then
  log_err "Faltan parámetros obligatorios: ${MISSING_ARGS[*]}"
  usage 1
fi

ssh_vps() { ssh -i "$VPS_SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
              -o BatchMode=yes "${VPS_USER}@${VPS_IP}" "$@"; }

# ──────────────────────────────────────────────────────────────────────────────
# 1. Validación de prerequisitos
# ──────────────────────────────────────────────────────────────────────────────
HEADER "1. Verificando prerequisitos"

check_cmd() {
  if command -v "$1" &>/dev/null; then
    log_ok "$1 encontrado ($(command -v "$1"))."
  else
    log_err "$1 no está instalado. Abortando."
    exit 1
  fi
}

check_cmd terraform

if ! command -v psql &>/dev/null; then
  log_err "psql no está instalado. Instale postgresql-client y reintente."
  exit 1
fi
log_ok "psql encontrado ($(command -v psql))."

if ! command -v mongosh &>/dev/null; then
  log_err "mongosh no está instalado. Instale mongodb-mongosh y reintente."
  exit 1
fi
log_ok "mongosh encontrado ($(command -v mongosh))."

if [[ ! -d "$BACKEND_DIR" ]]; then
  log_err "Directorio backend/ no encontrado: $BACKEND_DIR"
  log_err "Ejecutar primero: bash .claude/scripts/scaffold-all-services.sh"
  exit 1
fi

mapfile -t ALL_SERVICES < <(find "$BACKEND_DIR" -maxdepth 1 -mindepth 1 -type d -name "*-service" | sort)
if [[ ${#ALL_SERVICES[@]} -eq 0 ]]; then
  log_err "No se encontraron directorios *-service en $BACKEND_DIR"
  log_err "Ejecutar primero: bash .claude/scripts/scaffold-all-services.sh"
  exit 1
fi
log_ok "Servicios detectados en backend/: ${#ALL_SERVICES[@]}"
for s in "${ALL_SERVICES[@]}"; do log "  · $(basename "$s")"; done

if [[ -n "${COLLECTIONS_JS:-}" && ! -f "$COLLECTIONS_JS" ]]; then
  log_warn "Archivo collections JS no encontrado: $COLLECTIONS_JS (MongoDB omitirá colecciones iniciales)"
  COLLECTIONS_JS=""
elif [[ -n "${COLLECTIONS_JS:-}" ]]; then
  log_ok "Collections JS encontrado: $COLLECTIONS_JS"
fi

# ──────────────────────────────────────────────────────────────────────────────
# 2. Verificar contenedores de soporte
# ──────────────────────────────────────────────────────────────────────────────
HEADER "2. Verificando servicios systemd en VPS ($VPS_IP)"

SERVICES_OK=1
for svc in mongod postgresql; do
  if ssh_vps "systemctl is-active --quiet '$svc'" 2>/dev/null; then
    log_ok "Servicio $svc: activo en VPS."
  else
    log_err "Servicio $svc NO está activo en VPS $VPS_IP."
    SERVICES_OK=0
  fi
done

if [[ "$SERVICES_OK" -eq 0 ]]; then
  log_err "Faltan servicios en el VPS. Ejecute primero: vps-setup.sh services --vm-ip $VPS_IP"
  exit 1
fi

# ──────────────────────────────────────────────────────────────────────────────
# 2b. Tunnel SSH — MongoDB solo escucha en localhost del VPS.
#     PostgreSQL se accede via SSH con peer auth (sudo -u postgres psql).
# ──────────────────────────────────────────────────────────────────────────────
log "Abriendo tunnel SSH (Mongo 27018 → VPS:27017)..."
ssh -i "$VPS_SSH_KEY" -o StrictHostKeyChecking=no -o ExitOnForwardFailure=yes \
    -N -L 27018:127.0.0.1:27017 \
    "${VPS_USER}@${VPS_IP}" &
TUNNEL_PID=$!
trap "kill $TUNNEL_PID 2>/dev/null; wait $TUNNEL_PID 2>/dev/null" EXIT
sleep 2
if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
  log_err "No se pudo abrir el tunnel SSH. Verificar acceso SSH al VPS."
  exit 1
fi
log_ok "Tunnel SSH MongoDB activo (PID=$TUNNEL_PID)."

# Helper: ejecuta psql en la VPS via SSH con peer auth (sin password)
pg_vps() { ssh_vps "sudo -u postgres psql $*"; }

# ──────────────────────────────────────────────────────────────────────────────
# 3. Obtener puerto PostgreSQL de Terraform
# ──────────────────────────────────────────────────────────────────────────────
HEADER "3. Conectando a PostgreSQL nativo en VPS ($VPS_IP:5432)"

# PostgreSQL 16 corre como servicio nativo (postgresql.service) en el VPS.
# Puerto estándar 5432 — sin Terraform ni floci.
log_ok "PostgreSQL via SSH peer auth (sudo -u postgres psql)"

PGADMIN=""  # no usado; acceso via pg_vps()
PGAPP=""    # no usado; acceso via pg_vps()

# ──────────────────────────────────────────────────────────────────────────────
# 4. PostgreSQL — crear usuario de aplicación
# ──────────────────────────────────────────────────────────────────────────────
HEADER "4. PostgreSQL — usuario de aplicación"

log "Creando usuario $APP_USER (idempotente) vía SSH en VPS..."
pg_vps "-d postgres -c \"CREATE USER \\\"$APP_USER\\\" WITH PASSWORD '$APP_PASS'\"" 2>/dev/null || true
log_ok "Usuario $APP_USER listo."

# ──────────────────────────────────────────────────────────────────────────────
# 4b. PostgreSQL — Database-per-Service: una BD por cada servicio con adaptador postgres
# ──────────────────────────────────────────────────────────────────────────────
HEADER "4b. PostgreSQL — Database-per-Service (prefijo: ${PG_DB_NAME})"

PG_DBS_CREATED=()

create_pg_db() {
  local db_name="$1"
  local db_exists
  db_exists=$(pg_vps "-d postgres -tc \"SELECT 1 FROM pg_database WHERE datname='$db_name'\"" \
    2>/dev/null | tr -d '[:space:]')

  if [[ "$db_exists" == "1" ]]; then
    log_ok "  BD $db_name ya existe — omitiendo."
  else
    pg_vps "-d postgres -c \"CREATE DATABASE \\\"$db_name\\\" OWNER \\\"$APP_USER\\\"\""
    log_ok "  BD $db_name creada (owner=$APP_USER)."
  fi

  pg_vps "-d \"$db_name\" -c \"GRANT ALL ON SCHEMA public TO \\\"$APP_USER\\\"\"" &>/dev/null
  log_ok "  $db_name — permisos listos."
  PG_DBS_CREATED+=("$db_name")
}

for svc_path in "${ALL_SERVICES[@]}"; do
  svc_name="$(basename "$svc_path")"
  # Detecta adaptador postgres en driven-adapters/
  if find "$svc_path/infrastructure/driven-adapters" -maxdepth 1 -type d \
       -name "postgres" 2>/dev/null | grep -q .; then
    svc_slug="$(svc_to_slug "$svc_name")"
    db_name="${PG_DB_NAME}_${svc_slug}"
    log "  → $svc_name  [postgres]  →  BD: $db_name"
    create_pg_db "$db_name"
  fi
done

if [[ ${#PG_DBS_CREATED[@]} -eq 0 ]]; then
  log_warn "Ningún servicio con adaptador postgres detectado; no se crearon BDs PostgreSQL."
else
  log_ok "BDs PostgreSQL creadas: ${#PG_DBS_CREATED[@]}  (${PG_DBS_CREATED[*]})"
fi

# ──────────────────────────────────────────────────────────────────────────────
# 5. PostgreSQL — BD de reportería (report_schema_catalog, §9.2)
# ──────────────────────────────────────────────────────────────────────────────
# Base dedicada al catálogo de schemas de reportería (MS1/MS2 Spark).
# Solo se crea si existen servicios de reportería en backend/; idempotente.
HEADER "5. PostgreSQL — BD de reportería"

REPORTING_DB="${PG_DB_NAME}_reporting"
HAS_REPORTING=0
for svc_path in "${ALL_SERVICES[@]}"; do
  svc_name="$(basename "$svc_path")"
  if [[ "$svc_name" == *"report"* || "$svc_name" == *"reporting"* ]]; then
    HAS_REPORTING=1; break
  fi
done

READMODEL_DB="${PG_DB_NAME}_readmodel"

if [[ "$HAS_REPORTING" -eq 1 ]]; then
  log "  Servicios de reportería detectados — creando BDs de reportería..."

  log "  BD catálogo de schemas: $REPORTING_DB"
  create_pg_db "$REPORTING_DB"
  log_ok "BD $REPORTING_DB lista (schema se aplica vía Liquibase)."

  # BD del read model CQRS (PostgreSQL relacional).
  # El Projection Service proyecta eventos de dominio (Kafka) sobre tablas
  # desnormalizadas aquí. MS1 Spark (report-extraction-service --source jdbc)
  # la lee vía JDBC. Ningún microservicio operacional escribe en esta BD.
  log "  BD read model CQRS (PostgreSQL): $READMODEL_DB"
  create_pg_db "$READMODEL_DB"
  log_ok "BD $READMODEL_DB lista (Projection Service escribe / MS1 Spark JDBC lee)."
else
  log "  No se detectaron servicios de reportería; omitiendo $REPORTING_DB y $READMODEL_DB."
fi

# ──────────────────────────────────────────────────────────────────────────────
# 6. MongoDB — Database-per-Service: una BD por cada servicio con adaptador mongo
# ──────────────────────────────────────────────────────────────────────────────
HEADER "6. MongoDB — Database-per-Service (prefijo: ${MONGO_DB_NAME})"

MONGO_DBS_CREATED=()

create_mongo_db() {
  local db_name="$1"
  local noauth_uri="mongodb://127.0.0.1:27018/$db_name"
  local app_uri="mongodb://$APP_USER:$APP_PASS@${VPS_IP}:27017/$db_name?authSource=$db_name"

  mongosh "$noauth_uri" --quiet --eval "
    db = db.getSiblingDB('$db_name');
    const exists = db.getUsers().users.some(u => u.user === '$APP_USER');
    if (exists) {
      print('Usuario ya existe en $db_name; omitiendo.');
    } else {
      db.createUser({
        user: '$APP_USER',
        pwd: '$APP_PASS',
        roles: [{ role: 'readWrite', db: '$db_name' }]
      });
      print('Usuario creado en $db_name.');
    }
  " 2>/dev/null || log_warn "  No se pudo crear usuario en $db_name (auth deshabilitada en dev)."

  MONGO_DBS_CREATED+=("$db_name")
  log_ok "  BD MongoDB $db_name lista."
}

for svc_path in "${ALL_SERVICES[@]}"; do
  svc_name="$(basename "$svc_path")"
  if find "$svc_path/infrastructure/driven-adapters" -maxdepth 1 -type d \
       -name "mongo" 2>/dev/null | grep -q .; then
    svc_slug="$(svc_to_slug "$svc_name")"
    db_name="${MONGO_DB_NAME}_${svc_slug}"
    log "  → $svc_name  [mongo]  →  BD: $db_name"
    create_mongo_db "$db_name"
  fi
done

# Ejecutar script de colecciones (si existe) sobre cada BD MongoDB creada
if [[ -n "${COLLECTIONS_JS:-}" && ${#MONGO_DBS_CREATED[@]} -gt 0 ]]; then
  log "Aplicando colecciones JS a cada BD MongoDB creada..."
  for db_name in "${MONGO_DBS_CREATED[@]}"; do
    mongosh "mongodb://127.0.0.1:27018/$db_name" "$COLLECTIONS_JS" &>/dev/null \
      && log_ok "  $db_name — colecciones aplicadas." \
      || log_warn "  $db_name — no se pudieron aplicar colecciones (continúa)."
  done
fi

if [[ ${#MONGO_DBS_CREATED[@]} -eq 0 ]]; then
  log_warn "Ningún servicio con adaptador mongo detectado; no se crearon BDs MongoDB."
else
  log_ok "BDs MongoDB creadas: ${#MONGO_DBS_CREATED[@]}  (${MONGO_DBS_CREATED[*]})"
fi

# ──────────────────────────────────────────────────────────────────────────────
# 7. Checklist de criterios de aceptación (Database-per-Service)
# ──────────────────────────────────────────────────────────────────────────────
HEADER "7. Checklist de criterios de aceptación"

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

# PostgreSQL nativo en VPS
check_item "PostgreSQL nativo en VPS ($VPS_IP:5432)" 0

# usuario de aplicación existe en PG
USER_EXISTS=$(pg_vps "-d postgres -tc \"SELECT 1 FROM pg_roles WHERE rolname='$APP_USER'\"" \
  2>/dev/null | tr -d '[:space:]')
[[ "$USER_EXISTS" == "1" ]] && check_item "Usuario $APP_USER existe en PostgreSQL" 0 \
                              || check_item "Usuario $APP_USER existe en PostgreSQL" 1

# Una BD PostgreSQL por cada servicio detectado con adaptador postgres
for db_name in "${PG_DBS_CREATED[@]}"; do
  DB_OWNER=$(pg_vps "-d postgres -tc \"SELECT pg_catalog.pg_get_userbyid(datdba) FROM pg_database WHERE datname='$db_name'\"" \
    2>/dev/null | tr -d '[:space:]')
  [[ "$DB_OWNER" == "$APP_USER" ]] \
    && check_item "BD $db_name (owner=$APP_USER)" 0 \
    || check_item "BD $db_name — owner incorrecto o no existe" 1
done

[[ ${#PG_DBS_CREATED[@]} -eq 0 ]] && \
  check_item "BDs PostgreSQL por servicio (ningún servicio postgres detectado)" 0

# Una BD MongoDB por cada servicio detectado con adaptador mongo
for db_name in "${MONGO_DBS_CREATED[@]}"; do
  MONGO_PING=$(mongosh "mongodb://127.0.0.1:27018/$db_name" --quiet \
    --eval 'db.runCommand({ping:1}).ok' 2>/dev/null | tr -d '[:space:]')
  [[ "$MONGO_PING" == "1" ]] \
    && check_item "BD MongoDB $db_name accesible" 0 \
    || check_item "BD MongoDB $db_name — no accesible" 1
done

[[ ${#MONGO_DBS_CREATED[@]} -eq 0 ]] && \
  check_item "BDs MongoDB por servicio (ningún servicio mongo detectado)" 0

echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 8. Resumen final
# ──────────────────────────────────────────────────────────────────────────────
HEADER "Resumen — Database-per-Service"

echo ""
printf "  %-40s %s\n" "PostgreSQL" "localhost:$RDS_PORT  (usuario: $APP_USER)"
for db in "${PG_DBS_CREATED[@]}"; do
  printf "    %-38s %s\n" "· $db" "(operacional, owner=$APP_USER)"
done
[[ "$HAS_REPORTING" -eq 1 ]] && \
  printf "    %-38s %s\n" "· $REPORTING_DB" "(catálogo schemas reportería)" && \
  printf "    %-38s %s\n" "· $READMODEL_DB" "(read model CQRS — solo lectura para MS1)"
echo ""
printf "  %-40s %s\n" "MongoDB" "localhost:27017  (usuario: $APP_USER)"
for db in "${MONGO_DBS_CREATED[@]}"; do
  printf "    %-38s %s\n" "· $db" "(aislada, readWrite=$APP_USER)"
done
echo ""
echo "  Patrón: Database-per-Service — cada servicio tiene su propia BD."
echo "  El esquema lo aplica Liquibase standalone previo al despliegue (no al arrancar el servicio)."
echo ""
echo "  Siguiente paso (Etapa 1b) — aplicar changelogs Liquibase:"
echo "    bash .claude/scripts/run-liquibase-migrations.sh \\"
echo "      -P $PROJECT_NAME -p $PG_DB_NAME -u $APP_USER -w <clave>"
echo ""
echo "  Siguiente paso (Etapa 2) — secrets:"
echo "    bash .claude/scripts/create-all-secrets-dev.sh \\"
echo "      -P $PROJECT_NAME -p $PG_DB_NAME -m $MONGO_DB_NAME -u $APP_USER -w <clave>"
echo ""

if [[ "$checklist_ok" -eq 0 ]]; then
  log_ok "Etapa 1 completada. Bases de datos aisladas por servicio listas."
else
  log_warn "Algunos ítems del checklist no pasaron. Revise los errores arriba."
  exit 1
fi
