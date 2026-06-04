#!/usr/bin/env bash

# ===========================================================================
# init-dev-environment.sh — Paso 2: Inicializar el ambiente dev (floci)
#
# Prerrequisito: Paso 1 completado (base-infrastructure-builder.sh),
#                contenedores floci, MongoDB, Kafka y Gitea corriendo.
#
# Qué hace:
#   1. Verifica prerequisitos (Terraform, AWS CLI, Docker, curl, jq)
#   2. Inicializa el backend Terraform (terraform/backend/environments/dev)
#   3. terraform init / plan / apply -auto-approve
#   4. Verifica recursos emulados en floci (ECR, Cognito, Secrets Manager)
#   5. Verifica conectividad de contenedores de soporte
#   6. Muestra tabla de endpoints y captura outputs útiles
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
FLOCI_ENDPOINT="${FLOCI_ENDPOINT:-http://localhost:4566}"
AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_CMD="aws --endpoint-url=$FLOCI_ENDPOINT --region $AWS_REGION"

# ──────────────────────────────────────────────────────────────────────────────
# 0. Parámetros
# ──────────────────────────────────────────────────────────────────────────────
PROJECT_NAME=""
usage() {
  cat <<USAGE
Uso: $0 -P <proyecto>

  -P, --project NOMBRE   Slug del proyecto (el mismo usado en
                         base-infrastructure-builder.sh). Determina el nombre
                         del cluster K3d (<proyecto>-dev), el contenedor Kafka
                         (<proyecto>-kafka-dev) y la base PostgreSQL de dev
                         (<proyecto>_dev). (obligatorio)
USAGE
  exit "${1:-0}"
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    -P|--project) PROJECT_NAME="${2:-}"; shift 2 ;;
    --project=*)  PROJECT_NAME="${1#*=}"; shift ;;
    -h|--help)    usage 0 ;;
    *) log_err "Argumento desconocido: $1"; usage 1 ;;
  esac
done
if [[ -z "$PROJECT_NAME" ]]; then
  log_err "Falta el parámetro obligatorio -P/--project."
  usage 1
fi
KAFKA_CONTAINER="${PROJECT_NAME}-kafka-dev"
SONAR_CONTAINER="${PROJECT_NAME}-sonarqube"
K3D_CLUSTER="${PROJECT_NAME}-dev"
PG_DB_NAME="${PROJECT_NAME}_dev"

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
check_cmd curl
check_cmd jq

if ! command -v aws &>/dev/null; then
  log_warn "AWS CLI no encontrado: algunas verificaciones se omitirán."
else
  log_ok "aws encontrado ($(command -v aws))."
fi

if ! command -v docker &>/dev/null; then
  log_err "Docker no está instalado. Abortando."
  exit 1
fi
log_ok "docker encontrado ($(command -v docker))."

# ──────────────────────────────────────────────────────────────────────────────
# 2. Verificar que floci y contenedores de soporte estén corriendo
# ──────────────────────────────────────────────────────────────────────────────
HEADER "2. Verificando contenedores de soporte en floci-net"

CONTAINERS_EXPECTED=("floci" "floci-mongo" "$KAFKA_CONTAINER" "gitea" "$SONAR_CONTAINER")
ALL_UP=1

for c in "${CONTAINERS_EXPECTED[@]}"; do
  if docker ps --filter "name=$c" --filter "network=floci-net" --format '{{.Names}}' | grep -qx "$c"; then
    log_ok "Contenedor $c: UP en floci-net."
  else
    log_err "Contenedor $c NO está corriendo en floci-net."
    ALL_UP=0
  fi
done

if [[ "$ALL_UP" -eq 0 ]]; then
  log_err "Faltan contenedores de soporte. Ejecute primero: bash .claude/scripts/base-infrastructure-builder.sh"
  exit 1
fi

log_ok "Todos los contenedores de soporte están UP."

# ──────────────────────────────────────────────────────────────────────────────
# 3. Verificar salud del emulador floci
# ──────────────────────────────────────────────────────────────────────────────
HEADER "3. Salud del emulador floci"

if curl -sf "$FLOCI_ENDPOINT/_localstack/health" > /tmp/floci-health.json 2>/dev/null; then
  log "Servicios disponibles en floci:"
  jq -r '.services | to_entries[] | "  \(.key): \(.value)"' /tmp/floci-health.json
  rm -f /tmp/floci-health.json
else
  log_err "floci no responde en $FLOCI_ENDPOINT/_localstack/health"
  exit 1
fi

# ──────────────────────────────────────────────────────────────────────────────
# 4. Buscar directorio terraform/backend/environments/dev
# ──────────────────────────────────────────────────────────────────────────────
HEADER "4. Buscando ambiente dev de Terraform"

if [[ ! -d "$TF_DEV_DIR" ]]; then
  log_err "Directorio no encontrado: $TF_DEV_DIR"
  log_err "Ejecute primero: bash .claude/scripts/base-infrastructure-builder.sh"
  exit 1
fi

log_ok "Directorio encontrado: $TF_DEV_DIR"

# ──────────────────────────────────────────────────────────────────────────────
# 5. Terraform init
# ──────────────────────────────────────────────────────────────────────────────
HEADER "5. terraform init"

(
  cd "$TF_DEV_DIR"
  if [[ -f .terraform.lock.hcl ]]; then
    log_ok ".terraform.lock.hcl ya existe."
  fi
  terraform init
)

log_ok "terraform init completado."

# ──────────────────────────────────────────────────────────────────────────────
# 6. Terraform plan
# ──────────────────────────────────────────────────────────────────────────────
HEADER "6. terraform plan"

(
  cd "$TF_DEV_DIR"
  terraform plan
)

log_ok "terraform plan completado."

# ──────────────────────────────────────────────────────────────────────────────
# 7. Terraform apply
# ──────────────────────────────────────────────────────────────────────────────
HEADER "7. terraform apply"
log_warn "Aplicando infraestructura dev con floci + K3d..."
# En dev NO se usa EKS: el cluster Kubernetes es K3d ($K3D_CLUSTER), creado por
# base-infrastructure-builder.sh (floci-start). Los providers kubernetes/helm leen
# .kube/config-k3d, así que el cluster debe existir antes de este apply. El módulo
# 'argocd' instala ArgoCD en K3d vía Helm en el mismo apply (sin -target).
if ! kubectl --kubeconfig "$TF_DEV_DIR/.kube/config-k3d" get nodes &>/dev/null; then
  log_err "El cluster K3d $K3D_CLUSTER no responde. Ejecutá primero base-infrastructure-builder.sh."
  exit 1
fi
log_ok "Cluster K3d $K3D_CLUSTER accesible."

(
  cd "$TF_DEV_DIR"
  terraform apply -auto-approve
)

log_ok "terraform apply completado."

# ──────────────────────────────────────────────────────────────────────────────
# 8. Verificación de recursos emulados en floci
# ──────────────────────────────────────────────────────────────────────────────
HEADER "8. Verificando recursos emulados en floci"

if command -v aws &>/dev/null; then
  # ── ECR ──
  if $AWS_CMD ecr describe-repositories --query 'repositories[].repositoryName' --output table 2>/dev/null; then
    log_ok "ECR — repositorios listados."
  else
    log_warn "ECR — sin repositorios o falló la consulta."
  fi

  # ── Cognito ──
  if $AWS_CMD cognito-idp list-user-pools --max-results 10 --output table 2>/dev/null; then
    log_ok "Cognito — user pools listados."
  else
    log_warn "Cognito — sin user pools o falló la consulta."
  fi

  # ── Secrets Manager ──
  if $AWS_CMD secretsmanager list-secrets --query 'SecretList[].Name' --output table 2>/dev/null; then
    log_ok "Secrets Manager — secrets listados."
  else
    log_warn "Secrets Manager — sin secrets o falló la consulta."
  fi
else
  log_warn "aws CLI no disponible; omitiendo verificación de recursos floci."
fi

# ──────────────────────────────────────────────────────────────────────────────
# 8b. Verificación del cluster K3d + ArgoCD
# ──────────────────────────────────────────────────────────────────────────────
HEADER "8b. Verificando cluster K3d + ArgoCD"

if command -v kubectl &>/dev/null; then
  KUBE="kubectl --kubeconfig $TF_DEV_DIR/.kube/config-k3d"
  if $KUBE get nodes &>/dev/null; then
    log_ok "K3d — nodos:"
    $KUBE get nodes 2>/dev/null || true
  else
    log_warn "K3d — el cluster no respondió."
  fi
  if $KUBE get namespace argocd &>/dev/null; then
    log_ok "ArgoCD — namespace presente. Pods:"
    $KUBE -n argocd get pods 2>/dev/null || true
  else
    log_warn "ArgoCD — namespace 'argocd' no encontrado (¿terraform apply del módulo argocd?)."
  fi
else
  log_warn "kubectl no disponible; omitiendo verificación de K3d/ArgoCD."
fi

# ──────────────────────────────────────────────────────────────────────────────
# 9. Verificación de conectividad
# ──────────────────────────────────────────────────────────────────────────────
HEADER "9. Verificación de conectividad"

FAILED=()

# ── PostgreSQL (RDS emulado vía puerto dinámico) ──
RDS_PORT=$(cd "$TF_DEV_DIR" && terraform output -raw rds_port 2>/dev/null || echo "")
if [[ -n "$RDS_PORT" ]]; then
  log "PostgreSQL en localhost:$RDS_PORT"
  if command -v psql &>/dev/null; then
    if PGPASSWORD=changeme123 psql "postgresql://admin:changeme123@localhost:$RDS_PORT/$PG_DB_NAME" -c '\conninfo' &>/dev/null; then
      log_ok "PostgreSQL — conexión exitosa en localhost:$RDS_PORT."
    else
      log_err "PostgreSQL — falló la conexión en localhost:$RDS_PORT."
      FAILED+=("PostgreSQL")
    fi
  else
    log_warn "psql no instalado; omitiendo verificación PostgreSQL."
  fi
else
  log_warn "rds_port no disponible; omitiendo verificación PostgreSQL."
fi

# ── MongoDB ──
log "MongoDB en localhost:27017"
if command -v mongosh &>/dev/null; then
  if mongosh "mongodb://localhost:27017" --eval 'db.runCommand({ ping: 1 })' --quiet 2>/dev/null | grep -q '"ok" : 1'; then
    log_ok "MongoDB — ping exitoso."
  else
    log_err "MongoDB — falló el ping."
    FAILED+=("MongoDB")
  fi
else
  log_warn "mongosh no instalado; omitiendo verificación MongoDB."
fi

# ── Kafka ──
log "Kafka en localhost:29092"
if docker exec "$KAFKA_CONTAINER" /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list &>/dev/null; then
  log_ok "Kafka — respuesta del broker (lista de tópicos vacía esperada)."
else
  log_err "Kafka — no responde."
  FAILED+=("Kafka")
fi

# ── Gitea ──
if curl -sf http://localhost:3000/api/healthz &>/dev/null; then
  log_ok "Gitea — healthz OK."
else
  log_err "Gitea — healthz falló."
  FAILED+=("Gitea")
fi

# ── Cognito (vía AWS CLI) ──
if command -v aws &>/dev/null; then
  if $AWS_CMD cognito-idp list-user-pools --max-results 5 --output table &>/dev/null; then
    log_ok "Cognito — user pools accesibles."
  else
    log_err "Cognito — falló la consulta de user pools."
    FAILED+=("Cognito")
  fi
fi

# ──────────────────────────────────────────────────────────────────────────────
# 10. Outputs útiles y tabla de endpoints
# ──────────────────────────────────────────────────────────────────────────────
HEADER "10. Outputs de Terraform"

(
  cd "$TF_DEV_DIR"
  terraform output
)

HEADER "Tabla de endpoints locales"

echo ""
printf "  %-30s %-40s %s\n" "Recurso" "Endpoint host" "Puerto"
printf "  %-30s %-40s %s\n" "------------------------------" "----------------------------------------" "-----"
printf "  %-30s %-40s %s\n" "Emulador AWS floci" "$FLOCI_ENDPOINT" "4566"
printf "  %-30s %-40s %s\n" \
  "PostgreSQL (RDS emulado)" \
  "localhost:${RDS_PORT:-(ver terraform output rds_port)}" \
  "${RDS_PORT:-(ver output)}"
printf "  %-30s %-40s %s\n" "MongoDB" "mongodb://localhost:27017" "27017"
printf "  %-30s %-40s %s\n" "Kafka (host)" "localhost:29092" "29092"
printf "  %-30s %-40s %s\n" "Kafka (floci-net)" "${KAFKA_CONTAINER}:9092" "9092"
printf "  %-30s %-40s %s\n" "Gitea UI / API" "http://localhost:3000" "3000"
printf "  %-30s %-40s %s\n" "Gitea SSH" "localhost:2222" "2222"
printf "  %-30s %-40s %s\n" "SonarQube UI / API" "http://localhost:9000" "9000"
printf "  %-30s %-40s %s\n" "SonarQube (floci-net)" "${SONAR_CONTAINER}:9000" "9000"
echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 11. Outputs individuales útiles para frontend / backend
# ──────────────────────────────────────────────────────────────────────────────
HEADER "Outputs individuales (para uso en otros scripts)"

echo ""
cd "$TF_DEV_DIR"

echo "  # Puerto PostgreSQL"
echo "  RDS_PORT=$(terraform output -raw rds_port 2>/dev/null || echo '<no disponible>')"

echo "  # Cognito"
echo "  USER_POOL_ENDPOINT=$(terraform output -raw user_pool_endpoint 2>/dev/null || echo '<no disponible>')"
echo "  USER_POOL_ID=$(terraform output -raw user_pool_id 2>/dev/null || echo '<no disponible>')"
echo "  USER_POOL_CLIENT_ID=$(terraform output -raw client_id 2>/dev/null || echo '<no disponible>')"

echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 12. Checklist de verificación
# ──────────────────────────────────────────────────────────────────────────────
HEADER "Checklist de verificación"

PASS="✓"
FAIL="✗"

check_item() {
  local desc="$1" result="$2"
  if [[ "$result" -eq 0 ]]; then
    echo -e "  ${PASS} $desc"
  else
    echo -e "  ${FAIL} $desc"
    return 1
  fi
}

checklist_ok=0

# localstack/health con servicios disponibles
curl -sf "$FLOCI_ENDPOINT/_localstack/health" > /tmp/floci-health-check.json 2>/dev/null
if jq -e '.services.ecr? // empty | . != ""' /tmp/floci-health-check.json &>/dev/null && \
   jq -e '.services.secretsmanager? // empty | . != ""' /tmp/floci-health-check.json &>/dev/null && \
   jq -e '.services."cognito-idp"? // empty | . != ""' /tmp/floci-health-check.json &>/dev/null && \
   jq -e '.services.iam? // empty | . != ""' /tmp/floci-health-check.json &>/dev/null; then
  check_item "floci: ecr, secretsmanager, cognito-idp, iam disponibles" 0
else
  check_item "floci: ecr, secretsmanager, cognito-idp, iam disponibles" 1
  checklist_ok=1
fi
rm -f /tmp/floci-health-check.json

# psql conecta
if [[ -n "$RDS_PORT" ]] && command -v psql &>/dev/null; then
  if PGPASSWORD=changeme123 psql "postgresql://admin:changeme123@localhost:$RDS_PORT/$PG_DB_NAME" -c '\conninfo' &>/dev/null; then
    check_item "psql conecta a $PG_DB_NAME en localhost:$RDS_PORT" 0
  else
    check_item "psql conecta a $PG_DB_NAME en localhost:$RDS_PORT" 1
    checklist_ok=1
  fi
else
  check_item "psql conecta a $PG_DB_NAME (psql no disponible o rds_port vacío)" 1
  checklist_ok=1
fi

# mongosh ping
if command -v mongosh &>/dev/null; then
  if mongosh "mongodb://localhost:27017" --eval 'db.runCommand({ ping: 1 })' --quiet 2>/dev/null | grep -q '"ok" : 1'; then
    check_item "mongosh responde { ok: 1 } al ping" 0
  else
    check_item "mongosh responde { ok: 1 } al ping" 1
    checklist_ok=1
  fi
else
  check_item "mongosh responde ping (mongosh no disponible)" 1
  checklist_ok=1
fi

# kafka responde
if docker exec "$KAFKA_CONTAINER" /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list &>/dev/null; then
  check_item "kafka-topics --list responde" 0
else
  check_item "kafka-topics --list responde" 1
  checklist_ok=1
fi

# Gitea healthz OK
if curl -sf http://localhost:3000/api/healthz &>/dev/null; then
  check_item "Gitea /api/healthz responde OK" 0
else
  check_item "Gitea /api/healthz responde OK" 1
  checklist_ok=1
fi

echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 13. Resumen final
# ──────────────────────────────────────────────────────────────────────────────
if [[ ${#FAILED[@]} -eq 0 ]] && [[ "$checklist_ok" -eq 0 ]]; then
  log_ok "Paso 2 completado exitosamente. El ambiente dev está listo."
else
  if [[ ${#FAILED[@]} -gt 0 ]]; then
    log_err "Fallaron las verificaciones de conectividad: ${FAILED[*]}"
  fi
  if [[ "$checklist_ok" -ne 0 ]]; then
    log_warn "Algunos ítems del checklist no pasaron (ver arriba)."
  fi
  log_warn "Revise los errores anteriores."
  exit 1
fi
