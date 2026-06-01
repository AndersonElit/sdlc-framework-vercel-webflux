#!/usr/bin/env bash
# create-all-secrets-dev.sh
#
# Crea o actualiza los secrets de todos los *-service en floci (dev).
# No requiere editar ningún archivo por servicio: lee los valores dinámicos
# desde Terraform outputs y detecta el tipo de BD inspeccionando la estructura
# de driven-adapters generada por el scaffold.
#
# Uso:
#   bash .claude/scripts/create-all-secrets-dev.sh
#
# Variables de entorno opcionales (anulan los Terraform outputs):
#   RDS_PORT            Puerto dinámico de PostgreSQL RDS en floci
#   COGNITO_ISSUER_URI  Endpoint del User Pool de Cognito emulado
#   FLOCI_ENDPOINT      URL del emulador (default: http://localhost:4566)
#   AWS_REGION          Región (default: us-east-1)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BACKEND_DIR="${REPO_ROOT}/backend"
TF_DEV_DIR="${REPO_ROOT}/terraform/backend/environments/dev"
FLOCI_ENDPOINT="${FLOCI_ENDPOINT:-http://localhost:4566}"
AWS_REGION="${AWS_REGION:-us-east-1}"
SECRET_PREFIX="flexicredit/dev"

AWS_CMD="aws --endpoint-url=$FLOCI_ENDPOINT --region $AWS_REGION"

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

# Usar variable de entorno si está definida; si no, leer desde Terraform.
if [[ -z "${RDS_PORT:-}" ]]; then
  RDS_PORT=$(cd "$TF_DEV_DIR" && terraform output -raw rds_port 2>/dev/null || true)
fi

if [[ -z "${COGNITO_ISSUER_URI:-}" ]]; then
  COGNITO_ISSUER_URI=$(cd "$TF_DEV_DIR" && terraform output -raw user_pool_endpoint 2>/dev/null || true)
fi

if [[ -z "$RDS_PORT" ]]; then
  log_err "rds_port no disponible en Terraform outputs."
  log_err "Ejecutar: bash .claude/scripts/init-dev-environment.sh"
  log_err "O exportar: export RDS_PORT=<puerto>"
  exit 1
fi

if [[ -z "$COGNITO_ISSUER_URI" ]]; then
  log_warn "user_pool_endpoint no disponible; usando fallback local."
  COGNITO_ISSUER_URI="http://localhost:4566/us-east-1_dev"
fi

log_ok "RDS_PORT          = $RDS_PORT"
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
       -name "r2dbc-postgresql" 2>/dev/null | grep -q .; then
    echo "postgres"
  elif find "$svc_path/infrastructure/driven-adapters" -maxdepth 1 -type d \
       -name "mongo" 2>/dev/null | grep -q .; then
    echo "mongo"
  else
    echo "unknown"
  fi
}

# Detecta si el servicio tiene un driven-adapter productor de Kafka
# o un entry-point consumidor de Kafka.
detect_kafka() {
  local svc_path="$1"
  local has_producer has_consumer
  has_producer=$(find "$svc_path/infrastructure/driven-adapters" -maxdepth 1 -type d \
                   -name "kafka-producer" 2>/dev/null | wc -l)
  has_consumer=$(find "$svc_path/infrastructure/entry-points" -maxdepth 1 -type d \
                   -name "kafka-consumer" 2>/dev/null | wc -l)
  if [[ "$has_producer" -gt 0 || "$has_consumer" -gt 0 ]]; then
    echo "true"
  else
    echo "false"
  fi
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

  log "→ $svc_name  (db=$db_type  kafka=$uses_kafka)"

  case "$db_type" in
    postgres)
      secret_json=$(jq -n \
        --arg r2dbc   "r2dbc:postgresql://localhost:${RDS_PORT}/flexicredit_dev" \
        --arg user    "admin" \
        --arg pass    "changeme123" \
        --arg kafka   "localhost:29092" \
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
        --arg mongo   "mongodb://localhost:27017/flexicredit_audit" \
        --arg kafka   "localhost:29092" \
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

  if action="$(upsert_secret "$secret_name" "$secret_json")"; then
    log_ok "$svc_name — $action  →  $secret_name"
    ok+=("$svc_name")
  else
    log_err "$svc_name — falló el upsert del secret"
    failed+=("$svc_name")
  fi
done

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
