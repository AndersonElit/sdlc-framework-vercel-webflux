#!/usr/bin/env bash

# ===========================================================================
# scaffold-all-services.sh — Generar el scaffolding de microservicios
#                            (backend Spring Boot hexagonal) y frontend Next.js
#
# Prerrequisitos:
#   - Python 3 disponible
#   - Los templates .claude/templates/maven_hexagonal_scaffold.py y
#     .claude/templates/nextjs_feature_scaffold.py deben existir
#
# Qué hace:
#   1. Verifica prerequisitos (python3, templates)
#   2. Crea el directorio backend/ y frontend/
#   3. Backend — genera microservicios Spring Boot hexagonal
#   4. Frontend — genera proyecto Next.js feature-based
#   5. PostgreSQL — genera V1__initial_schema.sql por microservicio (Flyway)
#   6. seguridad-service — genera V2__seed_roles_permisos.sql
#   7. Checklist de verificación de directorios y migraciones generadas
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

TEMPLATES_DIR="$REPO_ROOT/.claude/templates"
MAVEN_TEMPLATE="$TEMPLATES_DIR/maven_hexagonal_scaffold.py"
NEXTJS_TEMPLATE="$TEMPLATES_DIR/nextjs_feature_scaffold.py"

BACKEND_DIR="$REPO_ROOT/backend"
FRONTEND_DIR="$REPO_ROOT/frontend"

SCHEMA_FILES=("$REPO_ROOT/docs/design/database"/*.sql)
SCHEMA_SQL="${SCHEMA_FILES[0]}"
SCHEMA_BASENAME="$(basename "$SCHEMA_SQL" 2>/dev/null || echo "schema.sql")"
REST_MODULE="rest-api"
MIGRATION_SUBPATH="src/main/resources/db/migration"

# ──────────────────────────────────────────────────────────────────────────────
# Argumentos de línea de comandos
#
# --backend nombre:db:messaging:puerto   (repetible, obligatorio)
#   Define un microservicio backend con su base de datos, mensajería y puerto.
#   Se puede usar tantas veces como servicios se desee generar.
#   Ejemplo:
#     --backend seguridad-service:postgres:none:8081
#
# --frontend nombre                       (opcional)
#   Nombre del proyecto frontend Next.js a generar.
#   Si se omite, no se genera frontend.
#   Ejemplo:
#     --frontend miproyecto-web
#
# --bc-tags servicio=TAG                  (repetible, opcional)
#   Mapea un microservicio PostgreSQL a su tag en el schema.sql para generar
#   las migraciones Flyway V1. Si se omite, no se generan migraciones.
#   Ejemplo:
#     --bc-tags clientes-service=BC-01
# ──────────────────────────────────────────────────────────────────────────────
BACKEND_SERVICES=()
FRONTEND_NAME=""
HAS_FRONTEND=0
declare -A BC_TAGS
PROJECT_NAME=""
PG_DB_NAME=""
MONGO_DB_NAME=""
DB_USER=""
DB_PASSWORD=""

usage() {
  cat <<EOF
Uso: $0 -P <proyecto> --backend nombre:db:messaging:puerto [--backend ...] \
        -p <pg-db> -m <mongo-db> -u <usuario> -w <clave> \
        [--frontend nombre] [--bc-tags servicio=TAG ...]

  -P, --project NOMBRE   Slug del proyecto. Se propaga como --org a los templates
                         (organización Gitea, prefijo de secrets, path del recurso
                         de la shared library). (obligatorio)

  --backend   Par nombre:db:messaging:puerto. Repetir una vez por servicio (obligatorio).
              db       = postgres | mongo
              messaging = none | kafka-producer | kafka-consumer | rabbit-producer | rabbit-consumer
              puerto   = número de puerto HTTP

  -p, --pg-db    NOMBRE   Base de datos PostgreSQL (obligatorio)
  -m, --mongo-db NOMBRE   Base de datos MongoDB    (obligatorio)
  -u, --user     NOMBRE   Usuario de aplicación    (obligatorio)
  -w, --password CLAVE    Clave del usuario         (obligatorio)

  --frontend  Nombre del proyecto frontend Next.js (opcional).
              Si se omite, no se genera frontend.

  --bc-tags   Par servicio=BC-XX (opcional, repetible).
              Mapea un servicio PostgreSQL a su tag en el schema.sql para
              generar V1__initial_schema.sql por Flyway.

Ejemplo:
  bash $0 \\
    -P miproyecto \\
    --backend seguridad-service:postgres:none:8081 \\
    --backend clientes-service:postgres:kafka-producer:8082 \\
    --backend configuracion-service:postgres:kafka-producer:8083 \\
    -p miproyecto_dev -m miproyecto_audit \\
    -u appuser -w secret123 \\
    --frontend miproyecto-web \\
    --bc-tags clientes-service=BC-01 \\
    --bc-tags configuracion-service=BC-02

EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -P|--project)
      if [[ -z "${2:-}" ]]; then
        log_err "--project requiere un valor (slug del proyecto)."
        exit 1
      fi
      PROJECT_NAME="$2"
      shift 2
      ;;
    --project=*)
      PROJECT_NAME="${1#*=}"
      shift
      ;;
    --backend)
      if [[ -z "${2:-}" ]]; then
        log_err "--backend requiere un valor (nombre:db:messaging:puerto)."
        exit 1
      fi
      BACKEND_SERVICES+=("$2")
      shift 2
      ;;
    --backend=*)
      VAL="${1#*=}"
      if [[ -z "$VAL" ]]; then
        log_err "--backend requiere un valor (nombre:db:messaging:puerto)."
        exit 1
      fi
      BACKEND_SERVICES+=("$VAL")
      shift
      ;;
    --frontend)
      if [[ -z "${2:-}" ]]; then
        log_err "--frontend requiere un valor (nombre del proyecto)."
        exit 1
      fi
      FRONTEND_NAME="$2"
      HAS_FRONTEND=1
      shift 2
      ;;
    --frontend=*)
      FRONTEND_NAME="${1#*=}"
      if [[ -z "$FRONTEND_NAME" ]]; then
        log_err "--frontend requiere un valor (nombre del proyecto)."
        exit 1
      fi
      HAS_FRONTEND=1
      shift
      ;;
    --bc-tags)
      if [[ -z "${2:-}" ]]; then
        log_err "--bc-tags requiere un valor (servicio=TAG)."
        exit 1
      fi
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
    -p|--pg-db)
      if [[ -z "${2:-}" ]]; then
        log_err "--pg-db requiere un valor (nombre de la base de datos PostgreSQL)."
        exit 1
      fi
      PG_DB_NAME="$2"
      shift 2
      ;;
    --pg-db=*)
      PG_DB_NAME="${1#*=}"
      shift
      ;;
    -m|--mongo-db)
      if [[ -z "${2:-}" ]]; then
        log_err "--mongo-db requiere un valor (nombre de la base de datos MongoDB)."
        exit 1
      fi
      MONGO_DB_NAME="$2"
      shift 2
      ;;
    --mongo-db=*)
      MONGO_DB_NAME="${1#*=}"
      shift
      ;;
    -u|--user)
      if [[ -z "${2:-}" ]]; then
        log_err "--user requiere un valor (usuario de aplicación)."
        exit 1
      fi
      DB_USER="$2"
      shift 2
      ;;
    --user=*)
      DB_USER="${1#*=}"
      shift
      ;;
    -w|--password)
      if [[ -z "${2:-}" ]]; then
        log_err "--password requiere un valor (clave del usuario)."
        exit 1
      fi
      DB_PASSWORD="$2"
      shift 2
      ;;
    --password=*)
      DB_PASSWORD="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      log_err "Argumento desconocido: $1"
      usage
      ;;
  esac
done

MISSING_ARGS=()
[[ -z "$PROJECT_NAME" ]] && MISSING_ARGS+=("-P/--project")
[[ "${#BACKEND_SERVICES[@]}" -eq 0 ]] && MISSING_ARGS+=("--backend")
[[ -z "$PG_DB_NAME"    ]] && MISSING_ARGS+=("-p/--pg-db")
[[ -z "$MONGO_DB_NAME" ]] && MISSING_ARGS+=("-m/--mongo-db")
[[ -z "$DB_USER"       ]] && MISSING_ARGS+=("-u/--user")
[[ -z "$DB_PASSWORD"   ]] && MISSING_ARGS+=("-w/--password")

if [[ ${#MISSING_ARGS[@]} -gt 0 ]]; then
  log_err "Faltan parámetros obligatorios: ${MISSING_ARGS[*]}"
  log_err "Ejecute con --help para ver la ayuda."
  exit 1
fi

log "Servicios backend: ${#BACKEND_SERVICES[@]} definidos."
if [[ "$HAS_FRONTEND" -eq 1 ]]; then
  log "Frontend: $FRONTEND_NAME"
else
  log "Frontend: omitido (no se especificó --frontend)."
fi
if [[ "${#BC_TAGS[@]}" -gt 0 ]]; then
  log "BC_TAGS: ${#BC_TAGS[@]} servicios para migraciones Flyway."
else
  log "BC_TAGS: omitidos (no se generarán migraciones Flyway V1)."
fi

# ──────────────────────────────────────────────────────────────────────────────
# 1. Validación de prerequisitos
# ──────────────────────────────────────────────────────────────────────────────
HEADER "1. Verificando prerequisitos"

if ! command -v python3 &>/dev/null; then
  log_err "python3 no está instalado. Abortando."
  exit 1
fi
log_ok "python3 encontrado ($(command -v python3))."

if [[ ! -f "$MAVEN_TEMPLATE" ]]; then
  log_err "Template no encontrado: $MAVEN_TEMPLATE"
  exit 1
fi
log_ok "Template Maven hexagonal encontrado: $MAVEN_TEMPLATE"

if [[ "$HAS_FRONTEND" -eq 1 ]]; then
  if [[ ! -f "$NEXTJS_TEMPLATE" ]]; then
    log_err "Template no encontrado: $NEXTJS_TEMPLATE"
    exit 1
  fi
  log_ok "Template Next.js encontrado: $NEXTJS_TEMPLATE"
else
  log "Template Next.js: omitido (no se generará frontend)."
fi

# Validar formato de cada --backend
for svc_spec in "${BACKEND_SERVICES[@]}"; do
  IFS=':' read -r name db messaging port <<< "$svc_spec"
  if [[ -z "$name" || -z "$db" || -z "$messaging" || -z "$port" ]]; then
    log_err "Formato inválido en --backend: '$svc_spec' (esperado nombre:db:messaging:puerto)."
    exit 1
  fi
done

# ──────────────────────────────────────────────────────────────────────────────
# 2. Crear directorios base
# ──────────────────────────────────────────────────────────────────────────────
HEADER "2. Creando directorios backend/ y frontend/"

mkdir -p "$BACKEND_DIR"
log_ok "Directorio backend/ creado: $BACKEND_DIR"

if [[ "$HAS_FRONTEND" -eq 1 ]]; then
  mkdir -p "$FRONTEND_DIR"
  log_ok "Directorio frontend/ creado: $FRONTEND_DIR"
fi

# ──────────────────────────────────────────────────────────────────────────────
# 3. Generar scaffolding de microservicios backend
# ──────────────────────────────────────────────────────────────────────────────
HEADER "3. Generando microservicios Spring Boot (${#BACKEND_SERVICES[@]} servicios)"

BACKEND_FAILED=()

for svc_spec in "${BACKEND_SERVICES[@]}"; do
  IFS=':' read -r name db messaging port <<< "$svc_spec"

  if [[ -d "$BACKEND_DIR/$name" ]]; then
    log_warn "$name — directorio ya existe; omitiendo."
    continue
  fi

  log "Generando $name (db=$db, messaging=$messaging, port=$port)..."
  if (cd "$BACKEND_DIR" && python3 "$MAVEN_TEMPLATE" -n "$name" -d "$db" -m "$messaging" -p "$port" --org "$PROJECT_NAME"); then
    log_ok "$name generado."
  else
    log_err "$name — falló la generación."
    BACKEND_FAILED+=("$name")
  fi
done

# ──────────────────────────────────────────────────────────────────────────────
# 4. Generar scaffolding frontend
# ──────────────────────────────────────────────────────────────────────────────
if [[ "$HAS_FRONTEND" -eq 1 ]]; then
  HEADER "4. Generando frontend Next.js"

  FRONTEND_FAILED=0

  if [[ -d "$FRONTEND_DIR/$FRONTEND_NAME" ]]; then
    log_warn "frontend/$FRONTEND_NAME — directorio ya existe; omitiendo."
  else
    log "Generando $FRONTEND_NAME..."
    if (cd "$FRONTEND_DIR" && python3 "$NEXTJS_TEMPLATE" -n "$FRONTEND_NAME" --org "$PROJECT_NAME"); then
      log_ok "$FRONTEND_NAME generado."
    else
      log_err "$FRONTEND_NAME — falló la generación."
      FRONTEND_FAILED=1
    fi
  fi
else
  FRONTEND_FAILED=0
  HEADER "4. Frontend omitido"
  log "No se especificó --frontend; sin frontend que generar."
fi

# ──────────────────────────────────────────────────────────────────────────────
# 5. PostgreSQL — generar migraciones Flyway V1 por microservicio
# ──────────────────────────────────────────────────────────────────────────────
HEADER "5. PostgreSQL — generando migraciones Flyway V1 por microservicio"

if [[ "${#BC_TAGS[@]}" -gt 0 ]]; then
  if [[ ! -f "$SCHEMA_SQL" ]]; then
    log_warn "Schema SQL no encontrado: $SCHEMA_SQL — omitiendo generación Flyway V1."
  else
    for SERVICE in "${!BC_TAGS[@]}"; do
      TAG="${BC_TAGS[$SERVICE]}"
      MIGRATION_DIR="$BACKEND_DIR/$SERVICE/$REST_MODULE/$MIGRATION_SUBPATH"
      V1_FILE="$MIGRATION_DIR/V1__initial_schema.sql"

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
-- Generado por: scaffold-all-services.sh
-- Fuente: docs/design/database/$SCHEMA_BASENAME
--
-- NOTA: Las tablas usan CREATE TABLE IF NOT EXISTS para ser idempotentes
-- en caso de que la base dev compartida ya las tenga del schema.sql global.

$BLOCK
EOF

      log_ok "$SERVICE — $V1_FILE generado."
    done
  fi
else
  log "Sin --bc-tags definidos; omitiendo generación de migraciones Flyway V1."
fi

# ──────────────────────────────────────────────────────────────────────────────
# 6. seguridad-service — generar V2__seed_roles_permisos.sql
# ──────────────────────────────────────────────────────────────────────────────
HEADER "6. seguridad-service — generando V2__seed_roles_permisos.sql"

SEGURIDAD_MIGRATION_DIR="$BACKEND_DIR/seguridad-service/$REST_MODULE/$MIGRATION_SUBPATH"
V2_FILE="$SEGURIDAD_MIGRATION_DIR/V2__seed_roles_permisos.sql"

if [[ -d "$BACKEND_DIR/seguridad-service" ]]; then
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
-- Generado por: scaffold-all-services.sh

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
else
  log "seguridad-service no encontrado en backend/; omitiendo V2 seed."
fi

# ──────────────────────────────────────────────────────────────────────────────
# 7. Checklist de verificación
# ──────────────────────────────────────────────────────────────────────────────
HEADER "7. Checklist de verificación"

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

# Verificar cada microservicio backend
for svc_spec in "${BACKEND_SERVICES[@]}"; do
  IFS=':' read -r name db messaging port <<< "$svc_spec"
  POM="$BACKEND_DIR/$name/pom.xml"
  [[ -f "$POM" ]] && check_item "$name — pom.xml existe" 0 \
                    || check_item "$name — pom.xml existe" 1
done

# Verificar frontend
if [[ "$HAS_FRONTEND" -eq 1 ]]; then
  PACKAGE_JSON="$FRONTEND_DIR/$FRONTEND_NAME/package.json"
  [[ -f "$PACKAGE_JSON" ]] && check_item "$FRONTEND_NAME — package.json existe" 0 \
                              || check_item "$FRONTEND_NAME — package.json existe" 1
fi

# Verificar migraciones Flyway V1
if [[ "${#BC_TAGS[@]}" -gt 0 ]]; then
  for SERVICE in "${!BC_TAGS[@]}"; do
    V1="$BACKEND_DIR/$SERVICE/$REST_MODULE/$MIGRATION_SUBPATH/V1__initial_schema.sql"
    [[ -f "$V1" ]] && check_item "$SERVICE — V1__initial_schema.sql existe" 0 \
                    || check_item "$SERVICE — V1__initial_schema.sql existe" 1
  done
fi

# Verificar V2 seed de seguridad-service
if [[ -d "$BACKEND_DIR/seguridad-service" ]]; then
  V2="$BACKEND_DIR/seguridad-service/$REST_MODULE/$MIGRATION_SUBPATH/V2__seed_roles_permisos.sql"
  [[ -f "$V2" ]] && check_item "seguridad-service — V2__seed_roles_permisos.sql existe" 0 \
                  || check_item "seguridad-service — V2__seed_roles_permisos.sql existe" 1
fi

echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 8. Resumen
# ──────────────────────────────────────────────────────────────────────────────
HEADER "Resumen"

GENERATED_COUNT=$(find "$BACKEND_DIR" -maxdepth 1 -mindepth 1 -type d -name "*-service" 2>/dev/null | wc -l)
echo ""
printf "  %-35s %s\n" "Microservicios backend" "${GENERATED_COUNT} generados"
if [[ "$HAS_FRONTEND" -eq 1 ]]; then
  printf "  %-35s %s\n" "Frontend" "$([[ -d "$FRONTEND_DIR/$FRONTEND_NAME" ]] && echo "$FRONTEND_NAME" || echo "NO generado")"
else
  printf "  %-35s %s\n" "Frontend" "omitido"
fi
if [[ "${#BC_TAGS[@]}" -gt 0 ]]; then
  printf "  %-35s %s\n" "Migraciones Flyway V1" "${#BC_TAGS[@]} servicios"
else
  printf "  %-35s %s\n" "Migraciones Flyway V1" "omitidas (sin --bc-tags)"
fi
echo ""

if [[ $checklist_ok -ne 0 ]] || [[ $FRONTEND_FAILED -ne 0 ]] || [[ ${#BACKEND_FAILED[@]} -gt 0 ]]; then
  if [[ ${#BACKEND_FAILED[@]} -gt 0 ]]; then
    log_err "Servicios backend fallidos: ${BACKEND_FAILED[*]}"
  fi
  if [[ $FRONTEND_FAILED -ne 0 ]]; then
    log_err "Frontend fallido: $FRONTEND_NAME"
  fi
  exit 1
fi

log_ok "Scaffolding completado exitosamente."

# ──────────────────────────────────────────────────────────────────────────────
# 9. Compilación backend
# ──────────────────────────────────────────────────────────────────────────────
HEADER "9. Compilación backend"

log "Ejecutando compile-services.sh..."
if bash "$SCRIPT_DIR/compile-services.sh"; then
  log_ok "Compilación backend completada."
else
  log_err "Compilación backend falló."
  exit 1
fi

# ──────────────────────────────────────────────────────────────────────────────
# 10. Verificación frontend
# ──────────────────────────────────────────────────────────────────────────────
if [[ "$HAS_FRONTEND" -eq 1 ]]; then
  HEADER "10. Verificación frontend"

  log "Ejecutando verify-frontend.sh..."
  if bash "$SCRIPT_DIR/verify-frontend.sh"; then
    log_ok "Verificación frontend completada."
  else
    log_err "Verificación frontend falló."
    exit 1
  fi
else
  HEADER "10. Verificación frontend omitida"
  log "No se especificó --frontend; sin frontend que verificar."
fi

# ──────────────────────────────────────────────────────────────────────────────
# 11. Secrets floci
# ──────────────────────────────────────────────────────────────────────────────
HEADER "11. Secrets floci"

log "Ejecutando create-all-secrets-dev.sh..."
if bash "$SCRIPT_DIR/create-all-secrets-dev.sh" \
     --project  "$PROJECT_NAME" \
     --pg-db    "$PG_DB_NAME" \
     --mongo-db "$MONGO_DB_NAME" \
     --user     "$DB_USER" \
     --password "$DB_PASSWORD"; then
  log_ok "Secrets creados en floci."
else
  log_err "Creación de secrets falló."
  exit 1
fi

# ──────────────────────────────────────────────────────────────────────────────
# 12. Terraform apply (dev — ECR + Secrets Manager)
# ──────────────────────────────────────────────────────────────────────────────
HEADER "12. Terraform apply (dev)"

TERRAFORM_DEV_DIR="$REPO_ROOT/terraform/backend/environments/dev"

if [[ ! -d "$TERRAFORM_DEV_DIR" ]]; then
  log_err "Directorio Terraform no encontrado: $TERRAFORM_DEV_DIR"
  exit 1
fi

log "Aplicando Terraform en $TERRAFORM_DEV_DIR..."
if (cd "$TERRAFORM_DEV_DIR" && terraform apply -auto-approve); then
  log_ok "Terraform apply completado."
else
  log_err "Terraform apply falló."
  exit 1
fi

# ──────────────────────────────────────────────────────────────────────────────
# 13. Verificación — repositorios ECR en floci
# ──────────────────────────────────────────────────────────────────────────────
HEADER "13. Verificación ECR en floci"

log "Listando repositorios ECR en floci (localhost:4566)..."
aws --endpoint-url=http://localhost:4566 ecr describe-repositories \
  --region us-east-1 \
  --query 'repositories[].repositoryName' \
  --output table \
  && log_ok "Repositorios ECR verificados." \
  || log_warn "No se pudieron listar los repositorios ECR (floci puede no estar levantado)."

# ──────────────────────────────────────────────────────────────────────────────
# 14. Verificación — secrets en floci
# ──────────────────────────────────────────────────────────────────────────────
HEADER "14. Verificación de secrets en floci"

log "Listando secrets ${PROJECT_NAME}/dev/* en Secrets Manager de floci..."
aws --endpoint-url=http://localhost:4566 secretsmanager list-secrets \
  --region us-east-1 \
  --query "SecretList[?starts_with(Name, \`${PROJECT_NAME}/dev/\`)].Name" \
  --output table \
  && log_ok "Secrets verificados." \
  || log_warn "No se pudieron listar los secrets (floci puede no estar levantado)."

log_ok "Pipeline post-scaffolding completado exitosamente."
