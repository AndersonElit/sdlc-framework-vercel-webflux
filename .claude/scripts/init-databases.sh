#!/usr/bin/env bash

# ===========================================================================
# init-databases.sh — Etapa 1: Inicializar bases de datos (PostgreSQL + MongoDB)
#
# Implementa el patrón Database-per-Service: cada microservicio detectado en
# backend/ recibe su propia base de datos aislada. Ningún servicio comparte
# base de datos con otro; la inicialización del esquema la hace Flyway al
# arrancar cada servicio (V1__initial_schema.sql generado por el scaffold).
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
#   6. Crea BD de reportería (<prefix>_reporting) para report_schema_catalog
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

if [[ ${#MISSING_ARGS[@]} -gt 0 ]]; then
  log_err "Faltan parámetros obligatorios: ${MISSING_ARGS[*]}"
  usage 1
fi

KAFKA_CONTAINER="${PROJECT_NAME}-kafka-dev"

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
check_cmd docker

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
HEADER "2. Verificando contenedores de soporte en floci-net"

CONTAINERS_REQUIRED=("floci" "floci-mongo" "$KAFKA_CONTAINER")
ALL_UP=1

for c in "${CONTAINERS_REQUIRED[@]}"; do
  if docker ps --filter "name=$c" --filter "network=floci-net" --format '{{.Names}}' | grep -qx "$c"; then
    log_ok "Contenedor $c: UP en floci-net."
  else
    log_err "Contenedor $c NO está corriendo en floci-net."
    ALL_UP=0
  fi
done

if [[ "$ALL_UP" -eq 0 ]]; then
  log_err "Faltan contenedores. Ejecute primero: bash .claude/scripts/init-dev-environment.sh"
  exit 1
fi

# ──────────────────────────────────────────────────────────────────────────────
# 3. Obtener puerto PostgreSQL de Terraform
# ──────────────────────────────────────────────────────────────────────────────
HEADER "3. Obteniendo puerto PostgreSQL (rds_port)"

if [[ ! -d "$TF_DEV_DIR" ]]; then
  log_err "Directorio no encontrado: $TF_DEV_DIR"
  log_err "Ejecute primero: bash .claude/scripts/init-dev-environment.sh"
  exit 1
fi

RDS_PORT=$(cd "$TF_DEV_DIR" && terraform output -raw rds_port 2>/dev/null || echo "")

if [[ -z "$RDS_PORT" ]]; then
  log_err "No se pudo obtener rds_port de terraform output. Verifique que init-dev-environment.sh finalizó con checklist ✓."
  exit 1
fi

log_ok "PostgreSQL en localhost:$RDS_PORT"

PGADMIN="postgresql://admin:changeme123@localhost:${RDS_PORT}"
PGAPP="postgresql://${APP_USER}:${APP_PASS}@localhost:${RDS_PORT}"

# ──────────────────────────────────────────────────────────────────────────────
# 4. PostgreSQL — crear usuario de aplicación
# ──────────────────────────────────────────────────────────────────────────────
HEADER "4. PostgreSQL — usuario de aplicación"

log "Creando usuario $APP_USER (idempotente)..."
PGPASSWORD=changeme123 psql "$PGADMIN/postgres" \
  -c "CREATE USER \"$APP_USER\" WITH PASSWORD '$APP_PASS'" 2>/dev/null || true
log_ok "Usuario $APP_USER listo."

# ──────────────────────────────────────────────────────────────────────────────
# 4b. PostgreSQL — Database-per-Service: una BD por cada servicio con adaptador postgres
# ──────────────────────────────────────────────────────────────────────────────
HEADER "4b. PostgreSQL — Database-per-Service (prefijo: ${PG_DB_NAME})"

PG_DBS_CREATED=()

create_pg_db() {
  local db_name="$1"
  local db_exists
  db_exists=$(PGPASSWORD=changeme123 psql "$PGADMIN/postgres" \
    -tc "SELECT 1 FROM pg_database WHERE datname='$db_name'" 2>/dev/null | tr -d '[:space:]')

  if [[ "$db_exists" == "1" ]]; then
    log_ok "  BD $db_name ya existe — omitiendo."
  else
    PGPASSWORD=changeme123 psql "$PGADMIN/postgres" \
      -c "CREATE DATABASE \"$db_name\" OWNER \"$APP_USER\""
    log_ok "  BD $db_name creada (owner=$APP_USER)."
  fi

  PGPASSWORD=changeme123 psql "$PGADMIN/$db_name" \
    -c "GRANT ALL ON SCHEMA public TO \"$APP_USER\"" &>/dev/null
  PGPASSWORD=changeme123 psql "$PGADMIN/$db_name" \
    -c "CREATE EXTENSION IF NOT EXISTS pgcrypto" &>/dev/null
  log_ok "  $db_name — permisos y pgcrypto listos."
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
  PGPASSWORD=changeme123 psql "$PGADMIN/$REPORTING_DB" -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE IF NOT EXISTS report_schema_catalog (
  report_type      TEXT PRIMARY KEY,
  schema_version   TEXT        NOT NULL,
  columns          JSONB       NOT NULL,
  integrity_rules  JSONB       NOT NULL DEFAULT '[]'::jsonb,
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
SQL
  log_ok "BD $REPORTING_DB + tabla report_schema_catalog lista."

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
  local noauth_uri="mongodb://localhost:27017/$db_name"
  local app_uri="mongodb://$APP_USER:$APP_PASS@localhost:27017/$db_name?authSource=$db_name"

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
    mongosh "mongodb://localhost:27017/$db_name" "$COLLECTIONS_JS" &>/dev/null \
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

# rds_port disponible
[[ -n "$RDS_PORT" ]] && check_item "terraform output rds_port disponible ($RDS_PORT)" 0 \
                      || check_item "terraform output rds_port disponible" 1

# usuario de aplicación existe en PG
USER_EXISTS=$(PGPASSWORD=changeme123 psql "$PGADMIN/postgres" \
  -tc "SELECT 1 FROM pg_roles WHERE rolname='$APP_USER'" 2>/dev/null | tr -d '[:space:]')
[[ "$USER_EXISTS" == "1" ]] && check_item "Usuario $APP_USER existe en PostgreSQL" 0 \
                              || check_item "Usuario $APP_USER existe en PostgreSQL" 1

# Una BD PostgreSQL por cada servicio detectado con adaptador postgres
for db_name in "${PG_DBS_CREATED[@]}"; do
  DB_OWNER=$(PGPASSWORD=changeme123 psql "$PGADMIN/postgres" \
    -tc "SELECT pg_catalog.pg_get_userbyid(datdba) FROM pg_database WHERE datname='$db_name'" \
    2>/dev/null | tr -d '[:space:]')
  EXT_OK=$(PGPASSWORD=changeme123 psql "$PGADMIN/$db_name" \
    -tc "SELECT 1 FROM pg_extension WHERE extname='pgcrypto'" 2>/dev/null | tr -d '[:space:]')
  [[ "$DB_OWNER" == "$APP_USER" ]] \
    && check_item "BD $db_name (owner=$APP_USER)" 0 \
    || check_item "BD $db_name — owner incorrecto o no existe" 1
  [[ "$EXT_OK" == "1" ]] \
    && check_item "  pgcrypto habilitada en $db_name" 0 \
    || check_item "  pgcrypto NO habilitada en $db_name" 1
done

[[ ${#PG_DBS_CREATED[@]} -eq 0 ]] && \
  check_item "BDs PostgreSQL por servicio (ningún servicio postgres detectado)" 0

# Una BD MongoDB por cada servicio detectado con adaptador mongo
for db_name in "${MONGO_DBS_CREATED[@]}"; do
  MONGO_PING=$(mongosh "mongodb://localhost:27017/$db_name" --quiet \
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
echo "  El esquema lo aplica Flyway al arrancar cada servicio (V1__initial_schema.sql)."
echo ""
echo "  Siguiente paso (Etapa 2):"
echo "    bash .claude/scripts/create-all-secrets-dev.sh \\"
echo "      -P $PROJECT_NAME -p $PG_DB_NAME -m $MONGO_DB_NAME -u $APP_USER -w <clave>"
echo ""

if [[ "$checklist_ok" -eq 0 ]]; then
  log_ok "Etapa 1 completada. Bases de datos aisladas por servicio listas."
else
  log_warn "Algunos ítems del checklist no pasaron. Revise los errores arriba."
  exit 1
fi
