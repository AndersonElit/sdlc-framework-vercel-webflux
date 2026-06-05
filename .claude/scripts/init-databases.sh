#!/usr/bin/env bash

# ===========================================================================
# init-databases.sh — Etapa 1: Inicializar bases de datos (PostgreSQL + MongoDB)
#
# Prerrequisito: Etapa 0 completada (init-dev-environment.sh finalizó con
#                checklist ✓ y terraform output rds_port disponible).
#
# Uso:
#   bash init-databases.sh -P <proyecto> -p <pg-db> -m <mongo-db> -u <usuario> -w <clave>
#
#   -P, --project  NOMBRE   Slug del proyecto (nombra el contenedor Kafka
#                           <proyecto>-kafka-dev y el prefijo de secrets)  (obligatorio)
#   -p, --pg-db    NOMBRE   Base de datos PostgreSQL a crear   (obligatorio)
#   -m, --mongo-db NOMBRE   Base de datos MongoDB a crear      (obligatorio)
#   -u, --user     NOMBRE   Usuario de aplicación a crear      (obligatorio)
#   -w, --password CLAVE    Clave del usuario de aplicación    (obligatorio)
#   -h, --help              Muestra esta ayuda
#
# Qué hace:
#   1. Verifica prerequisitos (psql, mongosh, terraform, docker)
#   2. Verifica que los contenedores floci, floci-mongo y Kafka estén UP
#   3. PostgreSQL — crea el usuario/clave indicados, crea la base (parámetro)
#      con ese owner y habilita pgcrypto
#   4. PostgreSQL — aplica el schema .sql del diseño sobre la base creada
#   5. MongoDB — crea la base (parámetro) con el usuario/clave indicados y
#      ejecuta el collections .js del diseño (colecciones + validadores)
#   6. Verificación final: colecciones, tablas, extensión
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

TF_DEV_DIR="$REPO_ROOT/terraform/backend/environments/dev"
SCHEMA_FILES=("$REPO_ROOT/docs/design/database"/*.sql)
SCHEMA_SQL="${SCHEMA_FILES[0]}"

COLLECTIONS_FILES=("$REPO_ROOT/docs/design/database"/*.js)
COLLECTIONS_JS="${COLLECTIONS_FILES[0]}"

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

# URIs de MongoDB: con autenticación (usuario de app) y sin autenticación.
MONGO_NOAUTH_URI="mongodb://localhost:27017/$MONGO_DB_NAME"
MONGO_APP_URI="mongodb://$APP_USER:$APP_PASS@localhost:27017/$MONGO_DB_NAME?authSource=$MONGO_DB_NAME"

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

if [[ ! -f "$SCHEMA_SQL" ]]; then
  log_err "Archivo no encontrado: $SCHEMA_SQL"
  exit 1
fi
log_ok "Schema SQL encontrado: $SCHEMA_SQL"

if [[ ! -f "$COLLECTIONS_JS" ]]; then
  log_err "Archivo no encontrado: $COLLECTIONS_JS"
  exit 1
fi
log_ok "Collections JS encontrado: $COLLECTIONS_JS"

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
# 4. PostgreSQL — crear usuario y base de datos de aplicación
# ──────────────────────────────────────────────────────────────────────────────
HEADER "4. PostgreSQL — usuario y base de datos '$PG_DB_NAME'"

log "Creando usuario $APP_USER (idempotente)..."
PGPASSWORD=changeme123 psql "$PGADMIN/postgres" \
  -c "CREATE USER \"$APP_USER\" WITH PASSWORD '$APP_PASS'" 2>/dev/null || true
log_ok "Usuario $APP_USER listo."

log "Creando base de datos $PG_DB_NAME si no existe..."
DB_EXISTS=$(PGPASSWORD=changeme123 psql "$PGADMIN/postgres" \
  -tc "SELECT 1 FROM pg_database WHERE datname='$PG_DB_NAME'" 2>/dev/null | tr -d '[:space:]')

if [[ "$DB_EXISTS" == "1" ]]; then
  log_ok "Base de datos $PG_DB_NAME ya existe."
else
  PGPASSWORD=changeme123 psql "$PGADMIN/postgres" \
    -c "CREATE DATABASE \"$PG_DB_NAME\" OWNER \"$APP_USER\""
  log_ok "Base de datos $PG_DB_NAME creada (owner=$APP_USER)."
fi

log "Otorgando permisos de schema public a $APP_USER..."
PGPASSWORD=changeme123 psql "$PGADMIN/$PG_DB_NAME" \
  -c "GRANT ALL ON SCHEMA public TO \"$APP_USER\""
log_ok "Permisos de schema public otorgados."

log "Habilitando extensión pgcrypto..."
PGPASSWORD=changeme123 psql "$PGADMIN/$PG_DB_NAME" \
  -c "CREATE EXTENSION IF NOT EXISTS pgcrypto"
log_ok "Extensión pgcrypto habilitada."

# ──────────────────────────────────────────────────────────────────────────────
# 5. PostgreSQL — aplicar esquema completo (inicialización dev)
# ──────────────────────────────────────────────────────────────────────────────
HEADER "5. PostgreSQL — aplicando $(basename "$SCHEMA_SQL")"

log "Aplicando esquema completo desde $SCHEMA_SQL ..."
PGPASSWORD="$APP_PASS" psql "$PGAPP/$PG_DB_NAME" -f "$SCHEMA_SQL"
log_ok "Esquema aplicado exitosamente."

TABLE_COUNT=$(PGPASSWORD="$APP_PASS" psql "$PGAPP/$PG_DB_NAME" -tc \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE'" \
  2>/dev/null | tr -d '[:space:]')
log_ok "Tablas en base $PG_DB_NAME: $TABLE_COUNT"

# ──────────────────────────────────────────────────────────────────────────────
# 5b. PostgreSQL — catálogo de esquemas de reportería (opcional, §9.2)
# ──────────────────────────────────────────────────────────────────────────────
# report_schema_catalog resuelve el ReportSchema vigente que MS1 valida (DR-1).
# Idempotente (CREATE TABLE IF NOT EXISTS); inofensivo si el proyecto no usa reportería.
HEADER "5b. PostgreSQL — catálogo de esquemas de reportería (report_schema_catalog)"

PGPASSWORD="$APP_PASS" psql "$PGAPP/$PG_DB_NAME" -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE IF NOT EXISTS report_schema_catalog (
  report_type      TEXT PRIMARY KEY,
  schema_version   TEXT        NOT NULL,
  columns          JSONB       NOT NULL,
  integrity_rules  JSONB       NOT NULL DEFAULT '[]'::jsonb,
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
SQL
log_ok "Tabla report_schema_catalog lista (catálogo de esquemas de reportería)."

# ──────────────────────────────────────────────────────────────────────────────
# 6. MongoDB — crear base/usuario y ejecutar script de colecciones
# ──────────────────────────────────────────────────────────────────────────────
HEADER "6. MongoDB — base de datos '$MONGO_DB_NAME' y colecciones"

log "Creando usuario $APP_USER sobre la base $MONGO_DB_NAME (idempotente)..."
mongosh "$MONGO_NOAUTH_URI" --quiet --eval "
  db = db.getSiblingDB('$MONGO_DB_NAME');
  const exists = db.getUsers().users.some(u => u.user === '$APP_USER');
  if (exists) {
    print('Usuario ya existe; omitiendo createUser.');
  } else {
    db.createUser({
      user: '$APP_USER',
      pwd: '$APP_PASS',
      roles: [{ role: 'readWrite', db: '$MONGO_DB_NAME' }]
    });
    print('Usuario creado.');
  }
" 2>/dev/null || log_warn "No se pudo crear el usuario (posible auth deshabilitada en el contenedor dev); se continúa sin credenciales."

# Selección de URI de ejecución: usa credenciales si la autenticación funciona,
# de lo contrario cae a la conexión sin autenticación (contenedor dev sin --auth).
if mongosh "$MONGO_APP_URI" --quiet --eval 'db.runCommand({ ping: 1 })' &>/dev/null; then
  MONGO_RUN_URI="$MONGO_APP_URI"
  log_ok "Usuario $APP_USER autenticado sobre $MONGO_DB_NAME."
else
  MONGO_RUN_URI="$MONGO_NOAUTH_URI"
  log_warn "Autenticación no disponible; ejecutando colecciones sin credenciales."
fi

log "Ejecutando $COLLECTIONS_JS contra $MONGO_DB_NAME ..."
mongosh "$MONGO_RUN_URI" "$COLLECTIONS_JS"
log_ok "Colecciones MongoDB creadas con validadores e índices."

# ──────────────────────────────────────────────────────────────────────────────
# 7. Verificación de MongoDB
# ──────────────────────────────────────────────────────────────────────────────
HEADER "7. Verificando colecciones MongoDB"

EXPECTED_COLLECTIONS=(
  "eventos_auditoria"
  "trazas_decision_automatica"
  "registros_acceso"
  "historicos_versionados"
  "deteccion_adulteracion"
  "vistas_cartera"
  "vistas_originacion"
)

MONGO_COLS=$(mongosh "$MONGO_RUN_URI" --quiet --eval \
  'db.getCollectionNames().join("\n")' 2>/dev/null || echo "")

MONGO_MISSING=()
for col in "${EXPECTED_COLLECTIONS[@]}"; do
  if echo "$MONGO_COLS" | grep -qx "$col"; then
    log_ok "Colección $col: presente."
  else
    log_err "Colección $col: NO encontrada."
    MONGO_MISSING+=("$col")
  fi
done

log "Índices de eventos_auditoria:"
mongosh "$MONGO_RUN_URI" --quiet --eval \
  'printjson(db.eventos_auditoria.getIndexes().map(i => i.name))' 2>/dev/null || true

# ──────────────────────────────────────────────────────────────────────────────
# 8. Checklist de criterios de aceptación
# ──────────────────────────────────────────────────────────────────────────────
HEADER "8. Checklist de criterios de aceptación"

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

# usuario de aplicación existe
USER_EXISTS=$(PGPASSWORD=changeme123 psql "$PGADMIN/postgres" \
  -tc "SELECT 1 FROM pg_roles WHERE rolname='$APP_USER'" 2>/dev/null | tr -d '[:space:]')
[[ "$USER_EXISTS" == "1" ]] && check_item "Usuario $APP_USER existe en PostgreSQL" 0 \
                              || check_item "Usuario $APP_USER existe en PostgreSQL" 1

# base de datos existe con owner correcto
DB_OWNER=$(PGPASSWORD=changeme123 psql "$PGADMIN/postgres" \
  -tc "SELECT pg_catalog.pg_get_userbyid(datdba) FROM pg_database WHERE datname='$PG_DB_NAME'" \
  2>/dev/null | tr -d '[:space:]')
[[ "$DB_OWNER" == "$APP_USER" ]] && check_item "Base $PG_DB_NAME existe (owner=$APP_USER)" 0 \
                                    || check_item "Base $PG_DB_NAME existe (owner=$APP_USER)" 1

# extensión pgcrypto habilitada
EXT_OK=$(PGPASSWORD="$APP_PASS" psql "$PGAPP/$PG_DB_NAME" \
  -tc "SELECT 1 FROM pg_extension WHERE extname='pgcrypto'" 2>/dev/null | tr -d '[:space:]')
[[ "$EXT_OK" == "1" ]] && check_item "Extensión pgcrypto habilitada" 0 \
                        || check_item "Extensión pgcrypto habilitada" 1

# schema.sql aplicado (al menos una tabla esperada)
CLIENTES_OK=$(PGPASSWORD="$APP_PASS" psql "$PGAPP/$PG_DB_NAME" \
  -tc "SELECT 1 FROM information_schema.tables WHERE table_name='clientes'" 2>/dev/null | tr -d '[:space:]')
[[ "$CLIENTES_OK" == "1" ]] && check_item "schema.sql aplicado (tabla 'clientes' presente)" 0 \
                              || check_item "schema.sql aplicado (tabla 'clientes' presente)" 1

# Las 7 colecciones MongoDB presentes
if [[ ${#MONGO_MISSING[@]} -eq 0 ]]; then
  check_item "7 colecciones MongoDB presentes en $MONGO_DB_NAME" 0
else
  check_item "7 colecciones MongoDB presentes (faltan: ${MONGO_MISSING[*]})" 1
fi

echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 9. Resumen final
# ──────────────────────────────────────────────────────────────────────────────
HEADER "Resumen"

echo ""
printf "  %-35s %s\n" "PostgreSQL"    "localhost:$RDS_PORT  (base: $PG_DB_NAME, user: $APP_USER)"
printf "  %-35s %s\n" "MongoDB"       "localhost:27017  (base: $MONGO_DB_NAME, user: $APP_USER)"
printf "  %-35s %s\n" "Tablas creadas" "$TABLE_COUNT"
printf "  %-35s %s\n" "Colecciones MongoDB" "${#EXPECTED_COLLECTIONS[@]} esperadas"
echo ""
echo "  NOTA: Los microservicios leen las credenciales de BD desde Secrets Manager"
echo "        (floci) en la ruta /${PROJECT_NAME}/dev/<servicio>. Ejecute la Etapa 2:"
echo "        bash .claude/scripts/create-all-secrets-dev.sh"
echo ""

if [[ "$checklist_ok" -eq 0 ]]; then
  log_ok "Etapa 1 completada exitosamente. Bases de datos listas."
else
  log_warn "Algunos ítems del checklist no pasaron (ver arriba). Revise los errores."
  exit 1
fi
