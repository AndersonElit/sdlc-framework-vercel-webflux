#!/usr/bin/env bash

# ===========================================================================
# init-databases.sh — Etapa 1: Inicializar bases de datos (PostgreSQL + MongoDB)
#
# Prerrequisito: Etapa 0 completada (init-dev-environment.sh finalizó con
#                checklist ✓ y terraform output rds_port disponible).
#
# Qué hace:
#   1. Verifica prerequisitos (psql, mongosh, terraform, docker)
#   2. Verifica que los contenedores floci, floci-mongo y Kafka estén UP
#   3. PostgreSQL — crea usuario flexicredit, base flexicredit, habilita pgcrypto
#   4. PostgreSQL — aplica SDD-FlexiCredit-schema.sql (inicialización dev)
#   5. MongoDB — ejecuta SDD-FlexiCredit-collections.js (colecciones + validadores)
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

MONGO_DB_NAME=$(mongosh "mongodb://localhost:27017" --quiet --eval \
  'db.adminCommand({ listDatabases: 1 }).databases.filter(d => !["admin","config","local"].includes(d.name)).map(d => d.name)[0]' 2>/dev/null || echo "")

if [[ -z "$MONGO_DB_NAME" ]]; then
  log_err "No se encontró una base de datos de aplicación en MongoDB. Ejecute el script de inicialización de colecciones primero."
  exit 1
fi

MONGO_URI="mongodb://localhost:27017/$MONGO_DB_NAME"

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

CONTAINERS_REQUIRED=("floci" "floci-mongo" "flexicredit-kafka-dev")
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
PGAPP="postgresql://flexicredit:flexicredit@localhost:${RDS_PORT}"

# ──────────────────────────────────────────────────────────────────────────────
# 4. PostgreSQL — crear usuario y base de datos de aplicación
# ──────────────────────────────────────────────────────────────────────────────
HEADER "4. PostgreSQL — usuario y base de datos de aplicación"

log "Creando usuario flexicredit (idempotente)..."
PGPASSWORD=changeme123 psql "$PGADMIN/postgres" \
  -c "CREATE USER flexicredit WITH PASSWORD 'flexicredit'" 2>/dev/null || true
log_ok "Usuario flexicredit listo."

log "Creando base de datos flexicredit si no existe..."
DB_EXISTS=$(PGPASSWORD=changeme123 psql "$PGADMIN/postgres" \
  -tc "SELECT 1 FROM pg_database WHERE datname='flexicredit'" 2>/dev/null | tr -d '[:space:]')

if [[ "$DB_EXISTS" == "1" ]]; then
  log_ok "Base de datos flexicredit ya existe."
else
  PGPASSWORD=changeme123 psql "$PGADMIN/postgres" \
    -c "CREATE DATABASE flexicredit OWNER flexicredit"
  log_ok "Base de datos flexicredit creada."
fi

log "Otorgando permisos de schema public a flexicredit..."
PGPASSWORD=changeme123 psql "$PGADMIN/flexicredit" \
  -c "GRANT ALL ON SCHEMA public TO flexicredit"
log_ok "Permisos de schema public otorgados."

log "Habilitando extensión pgcrypto..."
PGPASSWORD=changeme123 psql "$PGADMIN/flexicredit" \
  -c "CREATE EXTENSION IF NOT EXISTS pgcrypto"
log_ok "Extensión pgcrypto habilitada."

# ──────────────────────────────────────────────────────────────────────────────
# 5. PostgreSQL — aplicar esquema completo (inicialización dev)
# ──────────────────────────────────────────────────────────────────────────────
HEADER "5. PostgreSQL — aplicando $(basename "$SCHEMA_SQL")"

log "Aplicando esquema completo desde $SCHEMA_SQL ..."
PGPASSWORD=flexicredit psql "$PGAPP/flexicredit" -f "$SCHEMA_SQL"
log_ok "Esquema aplicado exitosamente."

TABLE_COUNT=$(PGPASSWORD=flexicredit psql "$PGAPP/flexicredit" -tc \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE'" \
  2>/dev/null | tr -d '[:space:]')
log_ok "Tablas en base flexicredit: $TABLE_COUNT"

# ──────────────────────────────────────────────────────────────────────────────
# 6. MongoDB — ejecutar script de colecciones y validadores
# ──────────────────────────────────────────────────────────────────────────────
HEADER "6. MongoDB — aplicando $(basename "$COLLECTIONS_JS")"

log "Ejecutando $COLLECTIONS_JS contra $MONGO_URI ..."
mongosh "$MONGO_URI" "$COLLECTIONS_JS"
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

MONGO_COLS=$(mongosh "$MONGO_URI" --quiet --eval \
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
mongosh "$MONGO_URI" --quiet --eval \
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

# usuario flexicredit existe
USER_EXISTS=$(PGPASSWORD=changeme123 psql "$PGADMIN/postgres" \
  -tc "SELECT 1 FROM pg_roles WHERE rolname='flexicredit'" 2>/dev/null | tr -d '[:space:]')
[[ "$USER_EXISTS" == "1" ]] && check_item "Usuario flexicredit existe en PostgreSQL" 0 \
                              || check_item "Usuario flexicredit existe en PostgreSQL" 1

# base flexicredit existe con owner correcto
DB_OWNER=$(PGPASSWORD=changeme123 psql "$PGADMIN/postgres" \
  -tc "SELECT pg_catalog.pg_get_userbyid(datdba) FROM pg_database WHERE datname='flexicredit'" \
  2>/dev/null | tr -d '[:space:]')
[[ "$DB_OWNER" == "flexicredit" ]] && check_item "Base flexicredit existe (owner=flexicredit)" 0 \
                                    || check_item "Base flexicredit existe (owner=flexicredit)" 1

# extensión pgcrypto habilitada
EXT_OK=$(PGPASSWORD=flexicredit psql "$PGAPP/flexicredit" \
  -tc "SELECT 1 FROM pg_extension WHERE extname='pgcrypto'" 2>/dev/null | tr -d '[:space:]')
[[ "$EXT_OK" == "1" ]] && check_item "Extensión pgcrypto habilitada" 0 \
                        || check_item "Extensión pgcrypto habilitada" 1

# schema.sql aplicado (al menos una tabla esperada)
CLIENTES_OK=$(PGPASSWORD=flexicredit psql "$PGAPP/flexicredit" \
  -tc "SELECT 1 FROM information_schema.tables WHERE table_name='clientes'" 2>/dev/null | tr -d '[:space:]')
[[ "$CLIENTES_OK" == "1" ]] && check_item "schema.sql aplicado (tabla 'clientes' presente)" 0 \
                              || check_item "schema.sql aplicado (tabla 'clientes' presente)" 1

# Las 7 colecciones MongoDB presentes
if [[ ${#MONGO_MISSING[@]} -eq 0 ]]; then
  check_item "7 colecciones MongoDB presentes en flexicredit_audit" 0
else
  check_item "7 colecciones MongoDB presentes (faltan: ${MONGO_MISSING[*]})" 1
fi

echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 9. Resumen final
# ──────────────────────────────────────────────────────────────────────────────
HEADER "Resumen"

echo ""
printf "  %-35s %s\n" "PostgreSQL"    "localhost:$RDS_PORT  (base: flexicredit, user: flexicredit)"
printf "  %-35s %s\n" "MongoDB"       "$MONGO_URI"
printf "  %-35s %s\n" "Tablas creadas" "$TABLE_COUNT"
printf "  %-35s %s\n" "Colecciones MongoDB" "${#EXPECTED_COLLECTIONS[@]} esperadas"
echo ""
echo "  NOTA: Los microservicios leen las credenciales de BD desde Secrets Manager"
echo "        (floci) en la ruta /flexicredit/dev/<servicio>. Ejecute la Etapa 2:"
echo "        bash .claude/scripts/create-all-secrets-dev.sh"
echo ""

if [[ "$checklist_ok" -eq 0 ]]; then
  log_ok "Etapa 1 completada exitosamente. Bases de datos listas."
else
  log_warn "Algunos ítems del checklist no pasaron (ver arriba). Revise los errores."
  exit 1
fi
