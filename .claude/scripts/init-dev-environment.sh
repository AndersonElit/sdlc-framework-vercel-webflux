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
AWS_REGION="${AWS_REGION:-us-east-1}"

# ──────────────────────────────────────────────────────────────────────────────
# 0. Parámetros
# ──────────────────────────────────────────────────────────────────────────────
PROJECT_NAME=""
VPS_IP=""
VPS_USER="${VPS_USER:-ubuntu}"
VPS_SSH_KEY="${VPS_SSH_KEY:-$HOME/.ssh/id_ed25519}"

usage() {
  cat <<USAGE
Uso: $0 -P <proyecto> --vps-ip <IP>

  -P, --project NOMBRE   Slug del proyecto (el mismo usado en
                         base-infrastructure-builder.sh). (obligatorio)
  --vps-ip IP            IP del VPS donde corren los servicios systemd
                         y K3s nativo.                                (obligatorio)
USAGE
  exit "${1:-0}"
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    -P|--project)  PROJECT_NAME="${2:-}"; shift 2 ;;
    --project=*)   PROJECT_NAME="${1#*=}"; shift ;;
    --vps-ip)      VPS_IP="${2:-}";       shift 2 ;;
    --vps-ip=*)    VPS_IP="${1#*=}";      shift ;;
    --vps-user)    VPS_USER="${2:-}";     shift 2 ;;
    --vps-ssh-key) VPS_SSH_KEY="${2:-}";  shift 2 ;;
    -h|--help)     usage 0 ;;
    *) log_err "Argumento desconocido: $1"; usage 1 ;;
  esac
done
if [[ -z "$PROJECT_NAME" ]]; then
  log_err "Falta el parámetro obligatorio -P/--project."
  usage 1
fi
if [[ -z "$VPS_IP" ]]; then
  log_err "Falta el parámetro obligatorio --vps-ip."
  usage 1
fi

FLOCI_ENDPOINT="http://${VPS_IP}:4566"
AWS_CMD="aws --endpoint-url=$FLOCI_ENDPOINT --region $AWS_REGION"

ssh_vps() { ssh -i "$VPS_SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
              -o BatchMode=yes "${VPS_USER}@${VPS_IP}" "$@"; }

K3S_CLUSTER="k3s-${PROJECT_NAME}-dev"
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

log "Verificando conectividad SSH al VPS ($VPS_IP)..."
ssh_vps "echo OK" &>/dev/null \
  || { log_err "No se puede conectar al VPS $VPS_IP via SSH."; exit 1; }
log_ok "VPS $VPS_IP accesible."

# ──────────────────────────────────────────────────────────────────────────────
# 2. Verificar servicios systemd en VPS
# ──────────────────────────────────────────────────────────────────────────────
HEADER "2. Verificando servicios systemd en VPS ($VPS_IP)"

SERVICES_EXPECTED=("mongod" "kafka" "gitea" "sonarqube" "jenkins")
ALL_UP=1

for c in "${SERVICES_EXPECTED[@]}"; do
  if ssh_vps "systemctl is-active --quiet '$c'" 2>/dev/null; then
    log_ok "Contenedor $c: UP en floci-net."
  else
    log_err "Servicio $c NO activo en VPS $VPS_IP."
    ALL_UP=0
  fi
done

if [[ "$ALL_UP" -eq 0 ]]; then
  log_err "Faltan servicios en el VPS. Ejecute primero: vps-setup.sh services --vm-ip $VPS_IP"
  exit 1
fi

log_ok "Todos los servicios systemd están activos en VPS."

# ──────────────────────────────────────────────────────────────────────────────
# 3. Verificar salud del emulador floci
# ──────────────────────────────────────────────────────────────────────────────
HEADER "3. Salud del emulador floci"

if curl -sf "$FLOCI_ENDPOINT/_localstack/health" > /tmp/floci-health.json 2>/dev/null; then
  log "Servicios disponibles en floci ($VPS_IP:4566):"
  jq -r '.services | to_entries[] | "  \(.key): \(.value)"' /tmp/floci-health.json
  rm -f /tmp/floci-health.json
else
  log_err "floci no responde en $FLOCI_ENDPOINT/_localstack/health"
  log_err "  Ejecuta en VPS: floci start  o  docker start floci"
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
log_warn "Aplicando infraestructura dev con floci + K3s (VPS nativo)..."
# En dev NO se usa EKS: el cluster Kubernetes es K3s nativo en el VPS ($VPS_IP:6443).
# ArgoCD ya fue instalado via Helm (vps-setup.sh k3s). Terraform aplica solo los
# recursos floci: Cognito, API Gateway, Secrets Manager, IAM.
if ! kubectl --kubeconfig "$TF_DEV_DIR/.kube/config-k3s" get nodes &>/dev/null 2>&1; then
  log_err "El cluster K3s en VPS no responde. Ejecutá primero base-infrastructure-builder.sh con --vps-ip $VPS_IP."
  exit 1
fi
log_ok "Cluster K3s ($K3S_CLUSTER) accesible en VPS $VPS_IP."

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
  # ── Gitea Package Registry (reemplaza ECR) ──
  if curl -sf -u gitea-admin:gitea-admin "http://${VPS_IP}:3000/api/v1/packages/${PROJECT_NAME}" &>/dev/null; then
    log_ok "Gitea Package Registry — accesible en http://${VPS_IP}:3000."
  else
    log_warn "Gitea Package Registry — no responde aún (esperar a que Gitea esté UP)."
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
HEADER "8b. Verificando cluster K3s + ArgoCD en VPS ($VPS_IP)"

if command -v kubectl &>/dev/null; then
  KUBE="kubectl --kubeconfig $TF_DEV_DIR/.kube/config-k3s"
  if $KUBE get nodes &>/dev/null; then
    log_ok "K3s (VPS nativo) — nodos:"
    $KUBE get nodes 2>/dev/null || true
  else
    log_warn "K3s — el cluster no respondió."
  fi
  if $KUBE get namespace argocd &>/dev/null; then
    log_ok "ArgoCD — namespace presente. Pods:"
    $KUBE -n argocd get pods 2>/dev/null || true
    log "  UI: http://${VPS_IP}:30080"
  else
    log_warn "ArgoCD — namespace 'argocd' no encontrado. Ejecutar: vps-setup.sh k3s --vm-ip $VPS_IP"
  fi
else
  log_warn "kubectl no disponible; omitiendo verificación de K3s/ArgoCD."
fi

# ──────────────────────────────────────────────────────────────────────────────
# 9. Verificación de conectividad
# ──────────────────────────────────────────────────────────────────────────────
HEADER "9. Verificación de conectividad"

FAILED=()

# ── PostgreSQL (nativo en VPS :5432) ──
log "PostgreSQL en $VPS_IP:5432"
if command -v psql &>/dev/null; then
  if PGPASSWORD=changeme123 psql "postgresql://admin:changeme123@${VPS_IP}:5432/${PG_DB_NAME}" -c '\conninfo' &>/dev/null; then
    log_ok "PostgreSQL — conexión exitosa en $VPS_IP:5432."
  else
    log_err "PostgreSQL — falló la conexión en $VPS_IP:5432."
    FAILED+=("PostgreSQL")
  fi
else
  log_warn "psql no instalado; omitiendo verificación PostgreSQL."
fi

# ── MongoDB (nativo en VPS :27017) ──
log "MongoDB en $VPS_IP:27017"
if command -v mongosh &>/dev/null; then
  if mongosh "mongodb://${VPS_IP}:27017" --eval 'db.runCommand({ ping: 1 })' --quiet 2>/dev/null | grep -q '"ok" : 1'; then
    log_ok "MongoDB — ping exitoso."
  else
    log_err "MongoDB — falló el ping."
    FAILED+=("MongoDB")
  fi
else
  log_warn "mongosh no instalado; omitiendo verificación MongoDB."
fi

# ── Kafka (systemd en VPS) ──
log "Kafka en $VPS_IP:9092"
if ssh_vps "/opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list" &>/dev/null; then
  log_ok "Kafka — respuesta del broker (lista de tópicos OK)."
else
  log_err "Kafka — no responde."
  FAILED+=("Kafka")
fi

# ── Gitea ──
if curl -sf "http://${VPS_IP}:3000/api/healthz" &>/dev/null; then
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

HEADER "Tabla de endpoints del VPS ($VPS_IP)"

echo ""
printf "  %-30s %-40s %s\n" "Recurso" "Endpoint" "Puerto"
printf "  %-30s %-40s %s\n" "------------------------------" "----------------------------------------" "-----"
printf "  %-30s %-40s %s\n" "Emulador AWS floci"      "http://${VPS_IP}:4566"             "4566"
printf "  %-30s %-40s %s\n" "PostgreSQL nativo"        "${VPS_IP}:5432"                    "5432"
printf "  %-30s %-40s %s\n" "MongoDB"                  "mongodb://${VPS_IP}:27017"         "27017"
printf "  %-30s %-40s %s\n" "Kafka (externo)"          "${VPS_IP}:29092"                   "29092"
printf "  %-30s %-40s %s\n" "Kafka (K3s pods)"         "${VPS_IP}:9092"                    "9092"
printf "  %-30s %-40s %s\n" "Gitea UI / API"           "http://${VPS_IP}:3000"             "3000"
printf "  %-30s %-40s %s\n" "Gitea Package Registry"   "http://${VPS_IP}:3000/${PROJECT_NAME}" "3000"
printf "  %-30s %-40s %s\n" "Gitea SSH"                "${VPS_IP}:2222"                    "2222"
printf "  %-30s %-40s %s\n" "SonarQube"                "http://${VPS_IP}:9000"             "9000"
printf "  %-30s %-40s %s\n" "Jenkins"                  "http://${VPS_IP}:8080"             "8080"
printf "  %-30s %-40s %s\n" "ArgoCD UI"                "http://${VPS_IP}:30080"            "30080"
printf "  %-30s %-40s %s\n" "K3s API"                  "https://${VPS_IP}:6443"            "6443"
echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 11. Outputs individuales útiles para frontend / backend
# ──────────────────────────────────────────────────────────────────────────────
HEADER "Outputs individuales (para uso en otros scripts)"

echo ""
cd "$TF_DEV_DIR"

echo "  # Gitea Package Registry"
echo "  GITEA_REGISTRY=$(terraform output -raw gitea_registry 2>/dev/null || echo "http://${VPS_IP}:3000/${PROJECT_NAME}")"

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
if jq -e '.services.secretsmanager? // empty | . != ""' /tmp/floci-health-check.json &>/dev/null && \
   jq -e '.services."cognito-idp"? // empty | . != ""' /tmp/floci-health-check.json &>/dev/null && \
   jq -e '.services.iam? // empty | . != ""' /tmp/floci-health-check.json &>/dev/null; then
  check_item "floci: secretsmanager, cognito-idp, iam disponibles" 0
else
  check_item "floci: ecr, secretsmanager, cognito-idp, iam disponibles" 1
  checklist_ok=1
fi
rm -f /tmp/floci-health-check.json

# psql conecta
if command -v psql &>/dev/null; then
  if PGPASSWORD=changeme123 psql "postgresql://admin:changeme123@${VPS_IP}:5432/${PG_DB_NAME}" -c '\conninfo' &>/dev/null; then
    check_item "psql conecta a $PG_DB_NAME en $VPS_IP:5432" 0
  else
    check_item "psql conecta a $PG_DB_NAME en $VPS_IP:5432" 1
    checklist_ok=1
  fi
else
  check_item "psql conecta a $PG_DB_NAME (psql no disponible)" 1
  checklist_ok=1
fi

# mongosh ping
if command -v mongosh &>/dev/null; then
  if mongosh "mongodb://${VPS_IP}:27017" --eval 'db.runCommand({ ping: 1 })' --quiet 2>/dev/null | grep -q '"ok" : 1'; then
    check_item "mongosh responde { ok: 1 } al ping en $VPS_IP:27017" 0
  else
    check_item "mongosh responde { ok: 1 } al ping en $VPS_IP:27017" 1
    checklist_ok=1
  fi
else
  check_item "mongosh responde ping (mongosh no disponible)" 1
  checklist_ok=1
fi

# kafka responde
if ssh_vps "/opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list" &>/dev/null; then
  check_item "kafka-topics --list responde en $VPS_IP:9092" 0
else
  check_item "kafka-topics --list responde en $VPS_IP:9092" 1
  checklist_ok=1
fi

# Gitea healthz OK
if curl -sf "http://${VPS_IP}:3000/api/healthz" &>/dev/null; then
  check_item "Gitea /api/healthz responde OK en $VPS_IP:3000" 0
else
  check_item "Gitea /api/healthz responde OK en $VPS_IP:3000" 1
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
