#!/usr/bin/env bash
# create-all-secrets-dev.sh
#
# Crea o actualiza los secrets de todos los *-service en floci (dev).
# No requiere editar ningún archivo por servicio: lee los valores dinámicos
# desde Terraform outputs y detecta el tipo de BD inspeccionando la estructura
# de driven-adapters generada por el scaffold.
#
# Uso:
#   bash .claude/scripts/create-all-secrets-dev.sh \
#     -P <proyecto> -p <pg-db> -m <mongo-db> -u <usuario> -w <clave>
#
#   -P, --project  NOMBRE   Slug del proyecto (prefijo de secrets <proyecto>/dev)  (obligatorio)
#   -p, --pg-db    NOMBRE   Base de datos PostgreSQL (obligatorio)
#   -m, --mongo-db NOMBRE   Base de datos MongoDB    (obligatorio)
#   -u, --user     NOMBRE   Usuario de aplicación    (obligatorio)
#   -w, --password CLAVE    Clave del usuario         (obligatorio)
#
# Variables de entorno opcionales (anulan los Terraform outputs):
#   RDS_PORT            Puerto dinámico de PostgreSQL RDS en floci
#   COGNITO_ISSUER_URI  Endpoint del User Pool de Cognito emulado
#   FLOCI_ENDPOINT      URL del emulador (default: http://<vps-ip>:4566)
#   AWS_REGION          Región (default: us-east-1)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BACKEND_DIR="${REPO_ROOT}/backend"
TF_DEV_DIR="${REPO_ROOT}/terraform/backend/environments/dev"
FLOCI_ENDPOINT="${FLOCI_ENDPOINT:-}"   # se fija tras parsear --vps-ip
AWS_REGION="${AWS_REGION:-us-east-1}"
SECRET_PREFIX=""   # se deriva de -P/--project: <proyecto>/dev

# ── Helpers de log ────────────────────────────────────────────────────────────
log()      { echo "[$(date '+%H:%M:%S')]     $*"; }
log_ok()   { echo "[$(date '+%H:%M:%S')] OK  $*"; }
log_err()  { echo "[$(date '+%H:%M:%S')] ERR $*" >&2; }
log_warn() { echo "[$(date '+%H:%M:%S')] WRN $*"; }

HEADER() {
  echo ""
  echo "── $* $(printf '%.0s─' {1..50})" | head -c 60
  echo ""
}

# ── Parámetros ────────────────────────────────────────────────────────────────
PROJECT_NAME=""
PG_DB_NAME=""
MONGO_DB_NAME=""
DB_USER=""
DB_PASSWORD=""
VPS_IP=""

usage() {
  sed -n '9,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -P|--project)  PROJECT_NAME="$2";  shift 2 ;;
    -p|--pg-db)    PG_DB_NAME="$2";    shift 2 ;;
    -m|--mongo-db) MONGO_DB_NAME="$2"; shift 2 ;;
    -u|--user)     DB_USER="$2";       shift 2 ;;
    -w|--password) DB_PASSWORD="$2";   shift 2 ;;
    --vps-ip)      VPS_IP="$2";        shift 2 ;;
    -h|--help)     usage 0 ;;
    *) log_err "Opción desconocida: $1"; usage 1 ;;
  esac
done

MISSING_ARGS=()
[[ -z "$PROJECT_NAME"  ]] && MISSING_ARGS+=("-P/--project")
[[ -z "$PG_DB_NAME"    ]] && MISSING_ARGS+=("-p/--pg-db")
[[ -z "$MONGO_DB_NAME" ]] && MISSING_ARGS+=("-m/--mongo-db")
[[ -z "$DB_USER"       ]] && MISSING_ARGS+=("-u/--user")
[[ -z "$DB_PASSWORD"   ]] && MISSING_ARGS+=("-w/--password")
[[ -z "$VPS_IP"        ]] && MISSING_ARGS+=("--vps-ip")

if [[ ${#MISSING_ARGS[@]} -gt 0 ]]; then
  log_err "Faltan parámetros obligatorios: ${MISSING_ARGS[*]}"
  usage 1
fi

SECRET_PREFIX="${PROJECT_NAME}/dev"
FLOCI_ENDPOINT="${FLOCI_ENDPOINT:-http://${VPS_IP}:4566}"
AWS_CMD="aws --endpoint-url=$FLOCI_ENDPOINT --region $AWS_REGION"

# ── Dependencias ──────────────────────────────────────────────────────────────
for dep in aws jq terraform; do
  if ! command -v "$dep" &>/dev/null; then
    log_err "Dependencia no encontrada: '$dep'. Instalarla antes de continuar."
    exit 1
  fi
done

# ── Paso 1: Leer Terraform outputs ────────────────────────────────────────────
HEADER "Paso 1 — Terraform outputs"

if [[ ! -d "$TF_DEV_DIR" ]]; then
  log_err "Directorio Terraform no encontrado: $TF_DEV_DIR"
  log_err "Ejecutar primero:"
  log_err "  bash .claude/scripts/base-infrastructure-builder.sh"
  log_err "  bash .claude/scripts/init-dev-environment.sh"
  exit 1
fi

# PostgreSQL nativo en VPS (puerto estándar 5432)
PG_HOST="$VPS_IP"
PG_PORT="5432"

if [[ -z "${COGNITO_ISSUER_URI:-}" ]]; then
  COGNITO_ISSUER_URI=$(cd "$TF_DEV_DIR" && terraform output -raw user_pool_endpoint 2>/dev/null || true)
fi

if [[ -z "$COGNITO_ISSUER_URI" ]]; then
  log_warn "user_pool_endpoint no disponible; usando fallback floci."
  COGNITO_ISSUER_URI="http://${VPS_IP}:4566/us-east-1_dev"
fi

log_ok "PostgreSQL VPS    = $PG_HOST:$PG_PORT"
log_ok "COGNITO_ISSUER_URI = $COGNITO_ISSUER_URI"

# ── Paso 2: Detectar servicios ────────────────────────────────────────────────
HEADER "Paso 2 — Detectar servicios"

if [[ ! -d "$BACKEND_DIR" ]]; then
  log_err "Directorio backend no encontrado: $BACKEND_DIR"
  log_err "Ejecutar primero: bash .claude/scripts/scaffold-all-services.sh"
  exit 1
fi

mapfile -t services < <(find "$BACKEND_DIR" -maxdepth 1 -mindepth 1 -type d -name "*-service" | sort)

if [[ ${#services[@]} -eq 0 ]]; then
  log_err "No se encontraron directorios *-service en $BACKEND_DIR"
  log_err "Ejecutar primero: bash .claude/scripts/scaffold-all-services.sh"
  exit 1
fi

log "Servicios detectados: ${#services[@]}"
for svc_path in "${services[@]}"; do
  log "  · $(basename "$svc_path")"
done

# ── Helpers de detección ──────────────────────────────────────────────────────

# Detecta el tipo de BD inspeccionando la carpeta driven-adapters del scaffold.
#   r2dbc-postgresql → postgres
#   mongo            → mongo
#   (ninguno)        → unknown
detect_db_type() {
  local svc_path="$1"
  if find "$svc_path/infrastructure/driven-adapters" -maxdepth 1 -type d \
       -name "postgres" 2>/dev/null | grep -q .; then
    echo "postgres"
  elif find "$svc_path/infrastructure/driven-adapters" -maxdepth 1 -type d \
       -name "mongo" 2>/dev/null | grep -q .; then
    echo "mongo"
  else
    echo "unknown"
  fi
}

# Detecta si el servicio tiene un driven-adapter productor de Kafka,
# un entry-point consumidor de Kafka, o el módulo Transactional Outbox
# (su relay también publica a Kafka).
detect_kafka() {
  local svc_path="$1"
  local has_producer has_consumer has_outbox
  has_producer=$(find "$svc_path/infrastructure/driven-adapters" -maxdepth 1 -type d \
                   -name "kafka-producer" 2>/dev/null | wc -l)
  has_consumer=$(find "$svc_path/infrastructure/entry-points" -maxdepth 1 -type d \
                   -name "kafka-consumer" 2>/dev/null | wc -l)
  has_outbox=$(find "$svc_path/infrastructure/driven-adapters" -maxdepth 1 -type d \
                 -name "outbox" 2>/dev/null | wc -l)
  if [[ "$has_producer" -gt 0 || "$has_consumer" -gt 0 || "$has_outbox" -gt 0 ]]; then
    echo "true"
  else
    echo "false"
  fi
}

# Detecta si el servicio es el integration-service (capa Camel + orquestador de saga):
# presencia de los driven-adapters camel-rest-consumer o saga-camel.
detect_integration() {
  local svc_path="$1"
  if find "$svc_path/infrastructure/driven-adapters" -maxdepth 1 -type d \
       \( -name "camel-rest-consumer" -o -name "saga-camel" \) 2>/dev/null | grep -q .; then
    echo "true"
  else
    echo "false"
  fi
}

# Lista los nombres de sistemas externos a partir de las rutas Camel (external.<name>.base-url).
detect_external_systems() {
  local svc_path="$1"
  grep -rho 'external\.[a-z0-9-]*\.base-url' \
    "$svc_path/infrastructure/driven-adapters/camel-rest-consumer" 2>/dev/null \
    | sed -E 's/external\.([a-z0-9-]*)\.base-url/\1/' | sort -u
}

# Upsert idempotente: actualiza el secret si ya existe, lo crea si no.
upsert_secret() {
  local secret_name="$1"
  local secret_json="$2"

  if $AWS_CMD secretsmanager describe-secret \
       --secret-id "$secret_name" &>/dev/null; then
    $AWS_CMD secretsmanager put-secret-value \
      --secret-id    "$secret_name" \
      --secret-string "$secret_json" \
      --output text --query 'VersionId' &>/dev/null
    echo "actualizado"
  else
    $AWS_CMD secretsmanager create-secret \
      --name          "$secret_name" \
      --secret-string "$secret_json" \
      --output text --query 'ARN' &>/dev/null
    echo "creado"
  fi
}

# ── Paso 3: Crear / actualizar secrets ───────────────────────────────────────
HEADER "Paso 3 — Upsert de secrets en floci"

ok=()
skipped=()
failed=()

for svc_path in "${services[@]}"; do
  svc_name="$(basename "$svc_path")"
  secret_name="${SECRET_PREFIX}/${svc_name}"

  db_type="$(detect_db_type "$svc_path")"
  uses_kafka="$(detect_kafka "$svc_path")"

  # Database-per-Service: cada servicio tiene su propia BD aislada.
  # Convención: <prefix>_<servicio_slug>  (guiones → guiones bajos)
  # Excepción CQRS: el Projection Service escribe sobre <prefix>_readmodel
  # (PostgreSQL relacional — read model compartido para MS1 Spark vía JDBC).
  svc_slug="${svc_name//-/_}"
  svc_mongo_db="${MONGO_DB_NAME}_${svc_slug}"

  if [[ "$svc_name" == *"projection"* ]] && [[ "$db_type" == "postgres" ]]; then
    svc_pg_db="${PG_DB_NAME}_readmodel"
    log "→ $svc_name  (db=postgres/readmodel  kafka=$uses_kafka  bd_propia=$svc_pg_db)"
  else
    svc_pg_db="${PG_DB_NAME}_${svc_slug}"
    log "→ $svc_name  (db=$db_type  kafka=$uses_kafka  bd_propia=${svc_pg_db:-${svc_mongo_db}})"
  fi

  case "$db_type" in
    postgres)
      secret_json=$(jq -n \
        --arg r2dbc   "r2dbc:postgresql://${PG_HOST}:${PG_PORT}/${svc_pg_db}" \
        --arg user    "$DB_USER" \
        --arg pass    "$DB_PASSWORD" \
        --arg kafka   "${VPS_IP}:29092" \
        --arg cognito "$COGNITO_ISSUER_URI" \
        '{
          R2DBC_URL:               $r2dbc,
          DB_USERNAME:             $user,
          DB_PASSWORD:             $pass,
          KAFKA_BOOTSTRAP_SERVERS: $kafka,
          COGNITO_ISSUER_URI:      $cognito
        }')
      ;;
    mongo)
      secret_json=$(jq -n \
        --arg mongo   "mongodb://${VPS_IP}:27017/${svc_mongo_db}" \
        --arg kafka   "${VPS_IP}:29092" \
        --arg cognito "$COGNITO_ISSUER_URI" \
        '{
          MONGODB_URI:             $mongo,
          KAFKA_BOOTSTRAP_SERVERS: $kafka,
          COGNITO_ISSUER_URI:      $cognito
        }')
      ;;
    unknown)
      log_warn "$svc_name: driven-adapter no detectado (r2dbc-postgresql o mongo). Omitiendo."
      skipped+=("$svc_name")
      continue
      ;;
  esac

  # Si el servicio no usa Kafka, eliminar la clave del JSON.
  if [[ "$uses_kafka" == "false" ]]; then
    secret_json=$(echo "$secret_json" | jq 'del(.KAFKA_BOOTSTRAP_SERVERS)')
  fi

  # integration-service: añadir coordinador LRA y URLs de sistemas externos (WireMock en dev).
  if [[ "$(detect_integration "$svc_path")" == "true" ]]; then
    lra_url="http://${VPS_IP}:50000/lra-coordinator"
    secret_json=$(echo "$secret_json" | jq --arg lra "$lra_url" '. + {LRA_COORDINATOR_URL: $lra}')
    while IFS= read -r ext; do
      [[ -z "$ext" ]] && continue
      ext_key="EXT_$(echo "$ext" | tr '[:lower:]-' '[:upper:]_')_BASE_URL"
      ext_val="http://${PROJECT_NAME}-wiremock:8080/${ext}"
      secret_json=$(echo "$secret_json" | jq --arg k "$ext_key" --arg v "$ext_val" '. + {($k): $v}')
      log "    + $ext_key → $ext_val"
    done < <(detect_external_systems "$svc_path")
  fi

  if action="$(upsert_secret "$secret_name" "$secret_json")"; then
    log_ok "$svc_name — $action  →  $secret_name"
    ok+=("$svc_name")
  else
    log_err "$svc_name — falló el upsert del secret"
    failed+=("$svc_name")
  fi
done

# ── Paso 3b: Secret del subsistema de reportería (§10.3) ──────────────────────
# Secret compartido por el ETL Spark (MS1/MS2) y la capa serverless de formatos.
# Idempotente: se crea/actualiza siempre; los servicios de reportería lo consumen
# solo si existen. En dev apunta a floci (:4566).
HEADER "Paso 3b — Secret de reportería"

reporting_secret="${SECRET_PREFIX}/reporting"
reporting_json=$(jq -n \
  --arg endpoint "http://${VPS_IP}:4566" \
  --arg bucket   "${PROJECT_NAME}-reports" \
  --arg kafka    "${VPS_IP}:29092" \
  --arg bus      "${PROJECT_NAME}-report-bus" \
  '{
    AWS_ENDPOINT_URL:        $endpoint,
    AWS_ACCESS_KEY_ID:       "test",
    AWS_SECRET_ACCESS_KEY:   "test",
    AWS_REGION:              "us-east-1",
    REPORT_BUCKET:           $bucket,
    KAFKA_BOOTSTRAP_SERVERS: $kafka,
    EVENTBRIDGE_BUS:         $bus
  }')

if action="$(upsert_secret "$reporting_secret" "$reporting_json")"; then
  log_ok "reporting — $action  →  $reporting_secret"
  ok+=("reporting")
else
  log_err "reporting — falló el upsert del secret de reportería"
  failed+=("reporting")
fi

# ── Resumen ───────────────────────────────────────────────────────────────────
HEADER "Resumen"

printf "  %-12s %d servicio(s)\n" "OK:"      "${#ok[@]}"
printf "  %-12s %d servicio(s)\n" "Omitidos:" "${#skipped[@]}"
printf "  %-12s %d servicio(s)\n" "Fallidos:" "${#failed[@]}"
echo ""

for s in "${ok[@]}";      do log_ok  "$s"; done
for s in "${skipped[@]}"; do log_warn "$s  (sin driven-adapter detectado)"; done
for s in "${failed[@]}";  do log_err  "$s" >&2; done

echo ""

if [[ ${#failed[@]} -gt 0 ]]; then
  log_err "Falló la creación de secrets para ${#failed[@]} servicio(s). Ver errores arriba."
  exit 1
fi

log "Secrets creados/actualizados correctamente en floci."
log "Para verificar:"
log "  aws --endpoint-url=$FLOCI_ENDPOINT secretsmanager list-secrets \\"
log "    --region $AWS_REGION \\"
log "    --query 'SecretList[?starts_with(Name, \`${SECRET_PREFIX}/\`)].Name' \\"
log "    --output table"
