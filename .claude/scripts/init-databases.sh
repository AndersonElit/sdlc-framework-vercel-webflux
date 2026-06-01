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
#   5. PostgreSQL — genera V1__initial_schema.sql por microservicio (Flyway)
#   6. seguridad-service — genera V2__seed_roles_permisos.sql
#   7. MongoDB — ejecuta SDD-FlexiCredit-collections.js (colecciones + validadores)
#   8. Verificación final: colecciones, tablas, extensión, migraciones
#   9. Checklist de criterios de aceptación
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
SCHEMA_SQL="$REPO_ROOT/docs/design/database/SDD-FlexiCredit-schema.sql"
COLLECTIONS_JS="$REPO_ROOT/docs/design/database/SDD-FlexiCredit-collections.js"

MONGO_URI="mongodb://localhost:27017/flexicredit_audit"

# ──────────────────────────────────────────────────────────────────────────────
# Argumentos de línea de comandos
#
# --bc-tags servicio=TAG   (repetible, obligatorio)
#   Mapea un microservicio PostgreSQL a su tag en el schema.sql.
#   Se puede usar tantas veces como servicios haya.
#   Ejemplo:
#     bash init-databases.sh \
#       --bc-tags clientes-service=BC-01 \
#       --bc-tags configuracion-service=BC-02
# ──────────────────────────────────────────────────────────────────────────────
declare -A BC_TAGS

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bc-tags)
      PAIR="$2"
      SERVICE="${PAIR%%=*}"
      TAG="${PAIR#*=}"
      if [[ -z "$SERVICE" || -z "$TAG" || "$SERVICE" == "$TAG" ]]; then
        log_err "Formato inválido en --bc-tags: '$PAIR' (esperado servicio=TAG)"
        exit 1
      fi
      BC_TAGS["$SERVICE"]="$TAG"
      shift 2
      ;;
    --bc-tags=*)
      PAIR="${1#*=}"
      SERVICE="${PAIR%%=*}"
      TAG="${PAIR#*=}"
      if [[ -z "$SERVICE" || -z "$TAG" || "$SERVICE" == "$TAG" ]]; then
        log_err "Formato inválido en --bc-tags: '$PAIR' (esperado servicio=TAG)"
        exit 1
      fi
      BC_TAGS["$SERVICE"]="$TAG"
      shift
      ;;
    -h|--help)
      echo "Uso: $0 --bc-tags servicio=TAG [--bc-tags servicio=TAG] ..."
      echo ""
      echo "  --bc-tags   Par servicio=BC-XX. Repetir una vez por servicio (obligatorio)."
      echo ""
      echo "  Ejemplo:"
      echo "    bash $0 \\"
      echo "      --bc-tags clientes-service=BC-01 \\"
      echo "      --bc-tags configuracion-service=BC-02"
      exit 0
      ;;
    *)
      log_err "Argumento desconocido: $1"
      exit 1
      ;;
  esac
done

if [[ "${#BC_TAGS[@]}" -eq 0 ]]; then
  log_err "Se requiere al menos un argumento --bc-tags servicio=TAG."
  log_err "Ejemplo: bash $0 --bc-tags clientes-service=BC-01 --bc-tags originacion-service=BC-03"
  exit 1
fi

log "BC_TAGS cargados desde --bc-tags (${#BC_TAGS[@]} servicios)."

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
HEADER "5. PostgreSQL — aplicando SDD-FlexiCredit-schema.sql"

log "Aplicando esquema completo desde $SCHEMA_SQL ..."
PGPASSWORD=flexicredit psql "$PGAPP/flexicredit" -f "$SCHEMA_SQL"
log_ok "Esquema aplicado exitosamente."

TABLE_COUNT=$(PGPASSWORD=flexicredit psql "$PGAPP/flexicredit" -tc \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE'" \
  2>/dev/null | tr -d '[:space:]')
log_ok "Tablas en base flexicredit: $TABLE_COUNT"

# ──────────────────────────────────────────────────────────────────────────────
# 6. PostgreSQL — generar migraciones Flyway V1 por microservicio
# ──────────────────────────────────────────────────────────────────────────────
HEADER "6. PostgreSQL — generando migraciones Flyway por microservicio"

# Módulo rest-api donde vive la carpeta de migraciones en la estructura hexagonal
REST_MODULE="rest-api"
MIGRATION_SUBPATH="src/main/resources/db/migration"

for SERVICE in "${!BC_TAGS[@]}"; do
  TAG="${BC_TAGS[$SERVICE]}"
  MIGRATION_DIR="$REPO_ROOT/backend/$SERVICE/$REST_MODULE/$MIGRATION_SUBPATH"
  V1_FILE="$MIGRATION_DIR/V1__initial_schema.sql"

  # Extraer bloque del bounded context desde el schema.sql.
  # Salta la línea del encabezado (-- BC-XX: ...) y acumula hasta el siguiente encabezado o EOF.
  BLOCK=$(awk -v tag="-- $TAG:" '
    $0 ~ tag        { found=1; next }
    found && /^-- BC-[0-9]+:/ { exit }
    found           { print }
  ' "$SCHEMA_SQL" 2>/dev/null | sed '/^[[:space:]]*$/N;/^\n$/d' || true)

  if [[ -z "$BLOCK" ]]; then
    log_warn "$SERVICE ($TAG) — bloque no encontrado en schema.sql; se generará un archivo vacío con cabecera."
    BLOCK="-- Extraer manualmente desde $SCHEMA_SQL las tablas de $TAG"
  fi

  if [[ -f "$V1_FILE" ]]; then
    log_warn "$SERVICE — $V1_FILE ya existe; omitiendo (no se sobreescribe)."
    continue
  fi

  if [[ ! -d "$MIGRATION_DIR" ]]; then
    mkdir -p "$MIGRATION_DIR"
    log "  Creado directorio: $MIGRATION_DIR"
  fi

  cat > "$V1_FILE" <<EOF
-- V1__initial_schema.sql
-- Microservicio: $SERVICE
-- Bounded Context: $TAG
-- Generado por: init-databases.sh
-- Fuente: docs/design/database/SDD-FlexiCredit-schema.sql
--
-- NOTA: Las tablas usan CREATE TABLE IF NOT EXISTS para ser idempotentes
-- en caso de que la base dev compartida ya las tenga del schema.sql global.

$BLOCK
EOF

  log_ok "$SERVICE — $V1_FILE generado."
done

# ──────────────────────────────────────────────────────────────────────────────
# 7. seguridad-service — generar V2__seed_roles_permisos.sql
# ──────────────────────────────────────────────────────────────────────────────
HEADER "7. seguridad-service — generando V2__seed_roles_permisos.sql"

SEGURIDAD_MIGRATION_DIR="$REPO_ROOT/backend/seguridad-service/$REST_MODULE/$MIGRATION_SUBPATH"
V2_FILE="$SEGURIDAD_MIGRATION_DIR/V2__seed_roles_permisos.sql"

if [[ -f "$V2_FILE" ]]; then
  log_warn "seguridad-service — $V2_FILE ya existe; omitiendo."
else
  if [[ ! -d "$SEGURIDAD_MIGRATION_DIR" ]]; then
    mkdir -p "$SEGURIDAD_MIGRATION_DIR"
  fi

  cat > "$V2_FILE" <<'EOF'
-- V2__seed_roles_permisos.sql
-- Microservicio: seguridad-service
-- Semilla: 7 roles del sistema, permisos por bounded context y mapeo roles_permisos
-- Generado por: init-databases.sh

-- Roles del sistema (7 roles definidos en el CHECK de la tabla roles)
INSERT INTO roles (id, nombre, descripcion, activo, created_at, updated_at)
VALUES
  (gen_random_uuid(), 'ADMIN',              'Administrador del sistema con acceso total',         true, NOW(), NOW()),
  (gen_random_uuid(), 'OFICIAL_CREDITO',    'Oficial de crédito — origina y evalúa solicitudes',  true, NOW(), NOW()),
  (gen_random_uuid(), 'ANALISTA_RIESGO',    'Analista de riesgo — revisiones manuales',           true, NOW(), NOW()),
  (gen_random_uuid(), 'CAJERO',             'Cajero — registro de pagos y desembolsos',           true, NOW(), NOW()),
  (gen_random_uuid(), 'AUDITOR',            'Auditor — acceso de solo lectura a auditoría',       true, NOW(), NOW()),
  (gen_random_uuid(), 'REPORTES',           'Usuario de reportes — acceso a vistas de cartera',   true, NOW(), NOW()),
  (gen_random_uuid(), 'SOPORTE',            'Soporte técnico — consultas operativas',              true, NOW(), NOW())
ON CONFLICT (nombre) DO NOTHING;

-- Permisos por bounded context y operación
INSERT INTO permisos (id, nombre, descripcion, recurso, accion, created_at, updated_at)
VALUES
  -- Gestión de Clientes
  (gen_random_uuid(), 'clientes:read',      'Leer clientes',          'clientes',      'READ',   NOW(), NOW()),
  (gen_random_uuid(), 'clientes:write',     'Crear/editar clientes',  'clientes',      'WRITE',  NOW(), NOW()),
  (gen_random_uuid(), 'clientes:delete',    'Eliminar clientes',      'clientes',      'DELETE', NOW(), NOW()),
  -- Configuración
  (gen_random_uuid(), 'configuracion:read', 'Leer configuración',     'configuracion', 'READ',   NOW(), NOW()),
  (gen_random_uuid(), 'configuracion:write','Editar configuración',   'configuracion', 'WRITE',  NOW(), NOW()),
  -- Originación
  (gen_random_uuid(), 'originacion:read',   'Leer solicitudes',       'originacion',   'READ',   NOW(), NOW()),
  (gen_random_uuid(), 'originacion:write',  'Crear solicitudes',      'originacion',   'WRITE',  NOW(), NOW()),
  (gen_random_uuid(), 'originacion:approve','Aprobar solicitudes',    'originacion',   'APPROVE',NOW(), NOW()),
  -- Tasas y Simulación
  (gen_random_uuid(), 'tasas:read',         'Consultar tasas',        'tasas',         'READ',   NOW(), NOW()),
  (gen_random_uuid(), 'tasas:write',        'Configurar tasas',       'tasas',         'WRITE',  NOW(), NOW()),
  -- Ciclo de Vida
  (gen_random_uuid(), 'ciclovida:read',     'Leer obligaciones',      'ciclovida',     'READ',   NOW(), NOW()),
  (gen_random_uuid(), 'ciclovida:write',    'Registrar pagos/abonos', 'ciclovida',     'WRITE',  NOW(), NOW()),
  -- Auditoría
  (gen_random_uuid(), 'auditoria:read',     'Leer eventos de auditoría','auditoria',   'READ',   NOW(), NOW()),
  -- Reportes
  (gen_random_uuid(), 'reportes:read',      'Consultar reportes',     'reportes',      'READ',   NOW(), NOW())
ON CONFLICT (nombre) DO NOTHING;

-- Mapeo roles_permisos: ADMIN obtiene todos los permisos
INSERT INTO roles_permisos (rol_id, permiso_id, created_at)
SELECT r.id, p.id, NOW()
FROM roles r, permisos p
WHERE r.nombre = 'ADMIN'
ON CONFLICT DO NOTHING;

-- OFICIAL_CREDITO
INSERT INTO roles_permisos (rol_id, permiso_id, created_at)
SELECT r.id, p.id, NOW()
FROM roles r
JOIN permisos p ON p.nombre IN (
  'clientes:read','clientes:write',
  'originacion:read','originacion:write',
  'tasas:read','configuracion:read'
)
WHERE r.nombre = 'OFICIAL_CREDITO'
ON CONFLICT DO NOTHING;

-- ANALISTA_RIESGO
INSERT INTO roles_permisos (rol_id, permiso_id, created_at)
SELECT r.id, p.id, NOW()
FROM roles r
JOIN permisos p ON p.nombre IN (
  'clientes:read',
  'originacion:read','originacion:approve',
  'tasas:read','configuracion:read'
)
WHERE r.nombre = 'ANALISTA_RIESGO'
ON CONFLICT DO NOTHING;

-- CAJERO
INSERT INTO roles_permisos (rol_id, permiso_id, created_at)
SELECT r.id, p.id, NOW()
FROM roles r
JOIN permisos p ON p.nombre IN (
  'clientes:read',
  'ciclovida:read','ciclovida:write'
)
WHERE r.nombre = 'CAJERO'
ON CONFLICT DO NOTHING;

-- AUDITOR
INSERT INTO roles_permisos (rol_id, permiso_id, created_at)
SELECT r.id, p.id, NOW()
FROM roles r
JOIN permisos p ON p.nombre IN ('auditoria:read')
WHERE r.nombre = 'AUDITOR'
ON CONFLICT DO NOTHING;

-- REPORTES
INSERT INTO roles_permisos (rol_id, permiso_id, created_at)
SELECT r.id, p.id, NOW()
FROM roles r
JOIN permisos p ON p.nombre IN ('reportes:read','ciclovida:read')
WHERE r.nombre = 'REPORTES'
ON CONFLICT DO NOTHING;

-- SOPORTE
INSERT INTO roles_permisos (rol_id, permiso_id, created_at)
SELECT r.id, p.id, NOW()
FROM roles r
JOIN permisos p ON p.nombre IN (
  'clientes:read','originacion:read',
  'ciclovida:read','tasas:read',
  'configuracion:read'
)
WHERE r.nombre = 'SOPORTE'
ON CONFLICT DO NOTHING;
EOF

  log_ok "seguridad-service — $V2_FILE generado."
fi

# ──────────────────────────────────────────────────────────────────────────────
# 8. MongoDB — ejecutar script de colecciones y validadores
# ──────────────────────────────────────────────────────────────────────────────
HEADER "8. MongoDB — aplicando SDD-FlexiCredit-collections.js"

log "Ejecutando $COLLECTIONS_JS contra $MONGO_URI ..."
mongosh "$MONGO_URI" "$COLLECTIONS_JS"
log_ok "Colecciones MongoDB creadas con validadores e índices."

# ──────────────────────────────────────────────────────────────────────────────
# 9. Verificación de MongoDB
# ──────────────────────────────────────────────────────────────────────────────
HEADER "9. Verificando colecciones MongoDB"

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
# 10. Checklist de criterios de aceptación
# ──────────────────────────────────────────────────────────────────────────────
HEADER "10. Checklist de criterios de aceptación"

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

# Migraciones Flyway V1 generadas para los 6 servicios PostgreSQL
for SERVICE in "${!BC_TAGS[@]}"; do
  V1="$REPO_ROOT/backend/$SERVICE/$REST_MODULE/$MIGRATION_SUBPATH/V1__initial_schema.sql"
  [[ -f "$V1" ]] && check_item "$SERVICE — V1__initial_schema.sql existe" 0 \
                  || check_item "$SERVICE — V1__initial_schema.sql existe" 1
done

# seguridad-service V2 seed
V2="$REPO_ROOT/backend/seguridad-service/$REST_MODULE/$MIGRATION_SUBPATH/V2__seed_roles_permisos.sql"
[[ -f "$V2" ]] && check_item "seguridad-service — V2__seed_roles_permisos.sql existe" 0 \
                || check_item "seguridad-service — V2__seed_roles_permisos.sql existe" 1

# Las 7 colecciones MongoDB presentes
if [[ ${#MONGO_MISSING[@]} -eq 0 ]]; then
  check_item "7 colecciones MongoDB presentes en flexicredit_audit" 0
else
  check_item "7 colecciones MongoDB presentes (faltan: ${MONGO_MISSING[*]})" 1
fi

echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 11. Resumen final
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
