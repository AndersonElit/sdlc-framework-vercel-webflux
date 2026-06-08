#!/usr/bin/env bash

set -euo pipefail

log() { echo "[$(date '+%H:%M:%S')] $*"; }
log_ok() { echo "[$(date '+%H:%M:%S')] OK  $*"; }
log_err() { echo "[$(date '+%H:%M:%S')] ERR $*" >&2; }

# ---------------------------------------------------------------------------
# Argumentos
# ---------------------------------------------------------------------------
PROJECT_NAME=""
VPS_IP=""
VPS_USER="${VPS_USER:-ubuntu}"
VPS_SSH_KEY="${VPS_SSH_KEY:-$HOME/.ssh/id_ed25519}"

usage() {
  cat <<USAGE
Uso: $0 -P <proyecto> --vps-ip <IP> [OPCIONES]

  -P, --project NOMBRE   Slug del proyecto en minúsculas (p. ej. 'mibanco').
                         Nombra el cluster K3s, la organización Gitea, los
                         recursos Terraform y el registry de imágenes. (obligatorio)
                         Recomendado: solo [a-z0-9-]; sin guiones para máxima
                         compatibilidad con nombres de base de datos.

  --vps-ip IP            IP del VPS Ubuntu 26.04 LTS donde corren los servicios
                         systemd (MongoDB, Kafka, Gitea, SonarQube, Jenkins, etc.)
                         Previamente configurado con vps-setup.sh. (obligatorio)

  --vps-user USER        Usuario SSH del VPS  (default: ubuntu, o \$VPS_USER)
  --vps-ssh-key FILE     Clave SSH privada    (default: ~/.ssh/id_ed25519, o \$VPS_SSH_KEY)
USAGE
  exit "${1:-0}"
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    -P|--project)    PROJECT_NAME="${2:-}"; shift 2 ;;
    --project=*)     PROJECT_NAME="${1#*=}"; shift ;;
    --vps-ip)        VPS_IP="${2:-}"; shift 2 ;;
    --vps-ip=*)      VPS_IP="${1#*=}"; shift ;;
    --vps-user)      VPS_USER="${2:-}"; shift 2 ;;
    --vps-ssh-key)   VPS_SSH_KEY="${2:-}"; shift 2 ;;
    -h|--help)       usage 0 ;;
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

# Helper SSH al VPS
ssh_vps() { ssh -i "$VPS_SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
              -o BatchMode=yes "${VPS_USER}@${VPS_IP}" "$@"; }

log "Iniciando base-infrastructure-builder (proyecto: $PROJECT_NAME, VPS: $VPS_IP)..."

log "Verificando dependencias locales..."
check_cmd() {
  if command -v "$1" &>/dev/null; then
    log_ok "$1 encontrado ($(command -v "$1"))."
  else
    log_err "$1 no está instalado. Abortando."
    exit 1
  fi
}
check_cmd terraform
check_cmd kubectl

log "Verificando conectividad SSH al VPS ($VPS_IP)..."
ssh_vps "echo OK" &>/dev/null \
  || { log_err "No se puede conectar al VPS $VPS_IP via SSH. Verifica la IP y la clave $VPS_SSH_KEY"; exit 1; }
log_ok "VPS $VPS_IP accesible via SSH."

# ---------------------------------------------------------------------------
# Verificar servicios en VPS (instalados previamente con vps-setup.sh)
# ---------------------------------------------------------------------------
log "Verificando servicios systemd en el VPS ($VPS_IP)..."
SERVICES_OK=true
for svc in mongod kafka gitea jenkins; do
  if ssh_vps "systemctl is-active --quiet '$svc'" 2>/dev/null; then
    log_ok "$svc activo en el VPS."
  else
    log_err "$svc NO está activo en el VPS. Ejecuta primero: vps-setup.sh services --vm-ip $VPS_IP"
    SERVICES_OK=false
  fi
done
[[ "$SERVICES_OK" == true ]] || exit 1

log "Verificando floci en el VPS ($VPS_IP)..."
if curl -sf "http://${VPS_IP}:4566/_localstack/health" &>/dev/null; then
  log_ok "floci activo en VPS ($VPS_IP:4566)."
else
  log "floci no activo — iniciando en VPS..."
  ssh_vps "floci start 2>/dev/null || docker start floci 2>/dev/null || true"
  sleep 5
  curl -sf "http://${VPS_IP}:4566/_localstack/health" &>/dev/null \
    && log_ok "floci iniciado." \
    || { log_err "No se pudo iniciar floci en el VPS. Ejecuta: vps-setup.sh floci --vm-ip $VPS_IP"; exit 1; }
fi

# ---------------------------------------------------------------------------
# MongoDB — verificar servicio systemd en VPS
# Corre como servicio nativo (mongod.service) en el VPS (vps-setup.sh services).
# Accesible desde microservicios vía $VPS_IP:27017.
# ---------------------------------------------------------------------------
log "Verificando MongoDB en VPS ($VPS_IP:27017)..."
if ssh_vps "systemctl is-active --quiet mongod" 2>/dev/null; then
  log_ok "MongoDB activo en VPS ($VPS_IP:27017)."
else
  log "Iniciando MongoDB en VPS..."
  ssh_vps "sudo systemctl start mongod"
  log_ok "MongoDB iniciado."
fi

# ---------------------------------------------------------------------------
# Apache Kafka — verificar servicio systemd en VPS (KRaft, sin ZooKeeper)
# Listeners: INTERNAL ($VPS_IP:9092) para microservicios, EXTERNAL ($VPS_IP:29092) CLI.
# El módulo terraform/backend/modules/msk queda reservado para staging/prod (AWS real).
# ---------------------------------------------------------------------------
log "Verificando Apache Kafka en VPS ($VPS_IP:9092)..."
if ssh_vps "systemctl is-active --quiet kafka" 2>/dev/null; then
  log_ok "Kafka activo en VPS ($VPS_IP:9092 / $VPS_IP:29092)."
else
  log "Iniciando Kafka en VPS..."
  ssh_vps "sudo systemctl start kafka"
  log_ok "Kafka iniciado."
fi

# ---------------------------------------------------------------------------
# Soporte de Saga (LRA) y contrato (WireMock) — servicios systemd en VPS
# ---------------------------------------------------------------------------
ENABLE_SAGA="${ENABLE_SAGA:-1}"
if [[ "$ENABLE_SAGA" == "1" ]]; then
  log "Verificando Narayana LRA Coordinator en VPS ($VPS_IP:50000)..."
  if ssh_vps "systemctl is-active --quiet lra-coordinator" 2>/dev/null; then
    log_ok "LRA Coordinator activo en VPS ($VPS_IP:50000)."
  else
    ssh_vps "sudo systemctl start lra-coordinator" && log_ok "LRA Coordinator iniciado." || true
  fi

  log "Verificando WireMock en VPS ($VPS_IP:9999)..."
  if ssh_vps "systemctl is-active --quiet wiremock" 2>/dev/null; then
    log_ok "WireMock activo en VPS ($VPS_IP:9999)."
  else
    ssh_vps "sudo systemctl start wiremock" && log_ok "WireMock iniciado." || true
  fi
else
  log "ENABLE_SAGA=0 — se omiten LRA Coordinator y WireMock."
fi

# ---------------------------------------------------------------------------
# Subsistema de reportería (ETL Spark + capa serverless de formatos)
#   - S3 (floci): bucket <proyecto>-reports con prefijos raw/ processed/ output/.
#   - Kafka:      topics report.extracted (MS1→MS2) y report.processed (MS2→serverless).
#   - EventBridge (floci): bus <proyecto>-report-bus (capa serverless, DR-8).
# Idempotente. Para omitir todo: ENABLE_REPORTING=0. Para omitir solo el bus
# serverless (mantener S3+topics): ENABLE_REPORTING_SERVERLESS=0 (DR-8).
# ---------------------------------------------------------------------------
ENABLE_REPORTING="${ENABLE_REPORTING:-1}"
ENABLE_REPORTING_SERVERLESS="${ENABLE_REPORTING_SERVERLESS:-1}"
if [[ "$ENABLE_REPORTING" == "1" ]]; then
  FLOCI_ENDPOINT="${FLOCI_ENDPOINT:-http://${VPS_IP}:4566}"
  REPORT_BUCKET="${PROJECT_NAME}-reports"
  REPORT_BUS="${PROJECT_NAME}-report-bus"

  # S3 bucket de reportería en floci (idempotente).
  log "Creando bucket S3 de reportería (s3://${REPORT_BUCKET}) en floci..."
  if aws --endpoint-url="$FLOCI_ENDPOINT" --region us-east-1 \
       s3api head-bucket --bucket "$REPORT_BUCKET" &>/dev/null; then
    log "Bucket ${REPORT_BUCKET} ya existe."
  else
    aws --endpoint-url="$FLOCI_ENDPOINT" --region us-east-1 \
      s3 mb "s3://${REPORT_BUCKET}" >/dev/null \
      && log_ok "Bucket ${REPORT_BUCKET} creado." \
      || log_warn "No se pudo crear el bucket ${REPORT_BUCKET} (¿floci arriba?)."
  fi

  # Topics Kafka de reportería (idempotente vía --if-not-exists).
  for topic in report.extracted report.processed; do
    log "Creando topic Kafka '$topic' (idempotente)..."
    ssh_vps "/opt/kafka/bin/kafka-topics.sh \
      --bootstrap-server localhost:9092 \
      --create --if-not-exists --topic '$topic' \
      --partitions 3 --replication-factor 1" >/dev/null 2>&1 \
      && log_ok "Topic '$topic' listo." \
      || log_warn "No se pudo crear el topic '$topic' (¿kafka activo en el VPS?)."
  done

  # Bus EventBridge de la capa serverless (idempotente). Las rules/lambdas las
  # crea el Terraform de terraform/backend/modules/reporting-lambdas (report_lambdas_scaffold.py).
  if [[ "$ENABLE_REPORTING_SERVERLESS" == "1" ]]; then
    log "Creando bus EventBridge de reportería (${REPORT_BUS}) en floci..."
    if aws --endpoint-url="$FLOCI_ENDPOINT" --region us-east-1 \
         events describe-event-bus --name "$REPORT_BUS" &>/dev/null; then
      log "Bus ${REPORT_BUS} ya existe."
    else
      aws --endpoint-url="$FLOCI_ENDPOINT" --region us-east-1 \
        events create-event-bus --name "$REPORT_BUS" >/dev/null \
        && log_ok "Bus ${REPORT_BUS} creado." \
        || log_warn "No se pudo crear el bus ${REPORT_BUS} (¿floci arriba?)."
    fi
  else
    log "ENABLE_REPORTING_SERVERLESS=0 — se omite el bus EventBridge (S3+topics conservados)."
  fi
else
  log "ENABLE_REPORTING=0 — se omite la provisión del subsistema de reportería."
fi

# ---------------------------------------------------------------------------
# Gitea — verificar servicio systemd en VPS
# Acceso: http://$VPS_IP:3000 (HTTP) / $VPS_IP:2222 (SSH)
# Package Registry OCI disponible en: http://$VPS_IP:3000/$PROJECT_NAME
# ---------------------------------------------------------------------------
log "Verificando Gitea en VPS ($VPS_IP:3000)..."
if ssh_vps "systemctl is-active --quiet gitea" 2>/dev/null; then
  log_ok "Gitea activo en VPS."
else
  log "Iniciando Gitea en VPS..."
  ssh_vps "sudo systemctl start gitea"
  sleep 5
fi

log "Esperando que Gitea esté listo..."
GITEA_READY=0
for i in $(seq 1 30); do
  if curl -sf "http://${VPS_IP}:3000/api/healthz" &>/dev/null; then
    GITEA_READY=1
    break
  fi
  sleep 2
done
if [[ "$GITEA_READY" -eq 0 ]]; then
  log_err "Gitea no respondió en 60 s. SSH al VPS y ejecuta: sudo systemctl status gitea"
  exit 1
fi

log "Verificando usuario admin en Gitea..."
GITEA_API="http://${VPS_IP}:3000/api/v1"
GITEA_AUTH="gitea-admin:gitea-admin"

# Verificar que la autenticación realmente funcione antes de seguir.
# Un fallo silencioso aquí deja a la org y a todos los repos sin crear (HTTP 401).
if ! curl -sf -u "$GITEA_AUTH" "$GITEA_API/user" &>/dev/null; then
  log_err "Autenticación gitea-admin falló (HTTP 401): el usuario admin no quedó creado."
  log_err "Revisar: docker exec -u git gitea gitea admin user list"
  exit 1
fi

log "Creando organización $PROJECT_NAME en Gitea..."
curl -sf -u "$GITEA_AUTH" -X POST "$GITEA_API/orgs" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"${PROJECT_NAME}\",\"visibility\":\"private\",\"repo_admin_change_team_access\":true}" \
  &>/dev/null \
  && log_ok "Organización $PROJECT_NAME creada." \
  || log "Organización $PROJECT_NAME ya existe."

log_ok "Gitea listo."
log "  UI:                http://${VPS_IP}:3000"
log "  Credenciales:      gitea-admin / gitea-admin"
log "  Organización:      $PROJECT_NAME"
log "  Package Registry:  http://${VPS_IP}:3000/${PROJECT_NAME}  (OCI/Docker nativo)"

# ---------------------------------------------------------------------------
# Estructura base de Terraform (frontend / backend desacoplados)
# ---------------------------------------------------------------------------
TERRAFORM_ROOT="${PROJECT_ROOT:-$(pwd)}/terraform"
TF_FRONTEND="$TERRAFORM_ROOT/frontend"
TF_BACKEND="$TERRAFORM_ROOT/backend"

log "Creando estructura Terraform en $TERRAFORM_ROOT..."

mkdir -p \
  "$TF_FRONTEND/modules/vercel-project" \
  "$TF_FRONTEND/environments/dev" \
  "$TF_FRONTEND/environments/staging" \
  "$TF_FRONTEND/environments/prod" \
  "$TF_BACKEND/modules/eks" \
  "$TF_BACKEND/modules/rds" \
  "$TF_BACKEND/modules/iam" \
  "$TF_BACKEND/modules/cognito" \
  "$TF_BACKEND/modules/api-gateway" \
  "$TF_BACKEND/modules/secrets-manager" \
  "$TF_BACKEND/modules/ecr" \
  "$TF_BACKEND/modules/jenkins" \
  "$TF_BACKEND/modules/msk" \
  "$TF_BACKEND/modules/argocd" \
  "$TF_BACKEND/modules/reporting-lambdas" \
  "$TF_BACKEND/environments/dev" \
  "$TF_BACKEND/environments/dev/argocd-bootstrap" \
  "$TF_BACKEND/environments/dev/.kube" \
  "$TF_BACKEND/environments/staging" \
  "$TF_BACKEND/environments/staging/argocd-bootstrap" \
  "$TF_BACKEND/environments/prod" \
  "$TF_BACKEND/environments/prod/argocd-bootstrap"

# ---------------------------------------------------------------------------
# Cluster Kubernetes de dev — K3d (K3s en Docker)
# ---------------------------------------------------------------------------
# El EKS de floci es solo emulación de metadatos (no hay API server real ni pods),
# así que el lazo CI/CD completo (Jenkins build → push → bumpImageTag → ArgoCD sync
# → pods) no puede cerrarse en dev. K3d levanta un Kubernetes REAL en contenedores
# Docker sobre la misma red floci-net, con un registry propio. Sobre él se instala
# ArgoCD (módulo terraform 'argocd' en dev) y Jenkins (contenedor en floci-net)
# lanza agentes como pods. Reemplaza por completo a EKS en dev.
#
# Nombres derivados de $PROJECT_NAME (referenciados por los providers de Terraform
# y el JCasC de Jenkins):
#   - cluster:        <proyecto>-dev   (contexto kubeconfig: k3d-<proyecto>-dev)
#   - API interno:    https://k3d-<proyecto>-dev-serverlb:6443  (desde floci-net)
#   - registry:       k3d-<proyecto>-registry:5100 (floci-net) / localhost:5100 (host)
#
# Se generan DOS kubeconfig:
#   - .kube/config-k3d           → server en localhost:<port>, para Terraform (host).
#   - .kube/config-k3d-internal  → server en serverlb:6443, para Jenkins (contenedor).
KUBE_DIR="$TF_BACKEND/environments/dev/.kube"

# ---------------------------------------------------------------------------
# SonarQube — verificar servicio systemd en VPS
# URL externa: http://$VPS_IP:9000
# La URL + token se persisten en .sonar-env para setup-cicd-pipeline.sh.
# ---------------------------------------------------------------------------
SONAR_URL_EXTERNAL="http://${VPS_IP}:9000"
SONAR_ADMIN_PASS="sonar-admin-dev"
SONAR_ENV_FILE="$TF_BACKEND/environments/dev/.sonar-env"

log "Verificando SonarQube en VPS ($VPS_IP:9000)..."
if ssh_vps "systemctl is-active --quiet sonarqube" 2>/dev/null; then
  log_ok "SonarQube activo en VPS."
else
  log "Iniciando SonarQube en VPS..."
  ssh_vps "sudo systemctl start sonarqube"
fi

log "Esperando que SonarQube esté listo (puede tardar 1-2 min)..."
SONAR_READY=0
for _ in $(seq 1 90); do
  status=$(curl -s "${SONAR_URL_EXTERNAL}/api/system/status" 2>/dev/null \
    | grep -o '"status":"[A-Z]*"' | cut -d'"' -f4 || true)
  if [[ "$status" == "UP" ]]; then
    SONAR_READY=1
    break
  fi
  sleep 3
done

if [[ "$SONAR_READY" -eq 0 ]]; then
  log_err "SonarQube no respondió UP en $VPS_IP:9000. SSH al VPS: sudo systemctl status sonarqube"
  log_err "  La infra continúa; SONAR_URL/SONAR_TOKEN quedarán pendientes en .env.jenkins."
else
  log_ok "SonarQube listo en $SONAR_URL_EXTERNAL."
  curl -s -u admin:admin -X POST \
    "${SONAR_URL_EXTERNAL}/api/users/change_password?login=admin&previousPassword=admin&password=${SONAR_ADMIN_PASS}" \
    -o /dev/null && log_ok "Password admin de SonarQube actualizado." \
    || log "Password admin ya estaba cambiado."
  curl -s -u "admin:${SONAR_ADMIN_PASS}" -X POST \
    "${SONAR_URL_EXTERNAL}/api/user_tokens/revoke?name=jenkins-ci" -o /dev/null || true
  SONAR_TOKEN_VALUE=$(curl -s -u "admin:${SONAR_ADMIN_PASS}" -X POST \
    "${SONAR_URL_EXTERNAL}/api/user_tokens/generate?name=jenkins-ci" 2>/dev/null \
    | grep -o '"token":"[^"]*"' | cut -d'"' -f4 || true)
  if [[ -n "$SONAR_TOKEN_VALUE" ]]; then
    mkdir -p "$TF_BACKEND/environments/dev"
    cat > "$SONAR_ENV_FILE" <<EOFSONAR
SONAR_URL=${SONAR_URL_EXTERNAL}
SONAR_TOKEN=${SONAR_TOKEN_VALUE}
EOFSONAR
    log_ok "Token de SonarQube persistido en $SONAR_ENV_FILE."
  else
    log_err "No se pudo generar token de SonarQube."
  fi
fi

# ---------------------------------------------------------------------------
# Cluster Kubernetes — K3s nativo en VPS (reemplaza K3d)
# kubeconfig descargado desde el VPS; context renombrado a k3s-vps.
# ---------------------------------------------------------------------------
log "Descargando kubeconfig de K3s desde el VPS..."
mkdir -p "$KUBE_DIR"
scp -i "$VPS_SSH_KEY" -o StrictHostKeyChecking=no \
  "${VPS_USER}@${VPS_IP}:/home/${VPS_USER}/.kube/config" \
  "$KUBE_DIR/config-k3s" 2>/dev/null \
  || { log_err "No se pudo descargar el kubeconfig de K3s. Ejecuta primero: vps-setup.sh k3s --vm-ip $VPS_IP"; exit 1; }

# El kubeconfig descargado ya tiene el VPS_IP como server; renombrar contexto.
sed -i "s|server: https://127.0.0.1|server: https://${VPS_IP}|g" "$KUBE_DIR/config-k3s" 2>/dev/null || true
kubectl --kubeconfig "$KUBE_DIR/config-k3s" config rename-context \
  "$(kubectl --kubeconfig "$KUBE_DIR/config-k3s" config current-context 2>/dev/null)" \
  "k3s-${PROJECT_NAME}-dev" 2>/dev/null || true

log "Esperando a que el API server de K3s responda..."
K3S_READY=0
for i in $(seq 1 30); do
  if kubectl --kubeconfig "$KUBE_DIR/config-k3s" get nodes &>/dev/null; then
    K3S_READY=1
    break
  fi
  sleep 2
done
if [[ "$K3S_READY" -eq 0 ]]; then
  log_err "K3s en VPS no respondió en 60 s. SSH al VPS: sudo systemctl status k3s"
  exit 1
fi
log_ok "K3s listo (VPS $VPS_IP:6443)."
log "  kubeconfig: $KUBE_DIR/config-k3s  (contexto k3s-${PROJECT_NAME}-dev)"
log "  Registry:   http://${VPS_IP}:3000/${PROJECT_NAME}  (Gitea Package Registry)"

# ===========================================================================
# FRONTEND — Helm chart K3s (reemplaza provider Vercel)
# Jenkins construye la imagen → push a Gitea Package Registry → ArgoCD deploya en K3s.
# ===========================================================================

log "Generando estructura Helm chart del frontend ($TF_FRONTEND)..."

mkdir -p \
  "$TF_FRONTEND/chart/templates" \
  "$TF_FRONTEND/environments/dev" \
  "$TF_FRONTEND/environments/staging" \
  "$TF_FRONTEND/environments/prod"

# Chart.yaml
cat > "$TF_FRONTEND/chart/Chart.yaml" << EOF
apiVersion: v2
name: ${PROJECT_NAME}-frontend
description: Frontend Next.js (K3s + Traefik Ingress)
type: application
version: 0.1.0
appVersion: "latest"
EOF

# values.yaml base
cat > "$TF_FRONTEND/chart/values.yaml" << EOF
replicaCount: 1

image:
  repository: ${VPS_IP}:3000/${PROJECT_NAME}/frontend
  tag: latest
  pullPolicy: Always

imagePullSecrets:
  - name: gitea-registry-secret

service:
  type: ClusterIP
  port: 3000

ingress:
  enabled: true
  className: traefik
  host: ""           # vacío = usar IP del nodo
  path: /
  pathType: Prefix

env:
  NEXT_PUBLIC_API_URL: "http://${VPS_IP}:8080"
EOF

# Deployment
cat > "$TF_FRONTEND/chart/templates/deployment.yaml" << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}-frontend
  labels:
    app: {{ .Release.Name }}-frontend
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Release.Name }}-frontend
  template:
    metadata:
      labels:
        app: {{ .Release.Name }}-frontend
    spec:
      imagePullSecrets:
        {{- toYaml .Values.imagePullSecrets | nindent 8 }}
      containers:
        - name: frontend
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - containerPort: 3000
          env:
            {{- range $k, $v := .Values.env }}
            - name: {{ $k }}
              value: "{{ $v }}"
            {{- end }}
          readinessProbe:
            httpGet:
              path: /
              port: 3000
            initialDelaySeconds: 10
            periodSeconds: 5
EOF

# Service
cat > "$TF_FRONTEND/chart/templates/service.yaml" << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}-frontend
spec:
  type: {{ .Values.service.type }}
  selector:
    app: {{ .Release.Name }}-frontend
  ports:
    - port: {{ .Values.service.port }}
      targetPort: 3000
EOF

# Ingress
cat > "$TF_FRONTEND/chart/templates/ingress.yaml" << 'EOF'
{{- if .Values.ingress.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ .Release.Name }}-frontend
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web
spec:
  ingressClassName: {{ .Values.ingress.className }}
  rules:
    - host: {{ .Values.ingress.host | default "" }}
      http:
        paths:
          - path: {{ .Values.ingress.path }}
            pathType: {{ .Values.ingress.pathType }}
            backend:
              service:
                name: {{ .Release.Name }}-frontend
                port:
                  number: {{ .Values.service.port }}
{{- end }}
EOF

# values por ambiente
for env in dev staging prod; do
  cat > "$TF_FRONTEND/environments/$env/values.yaml" << EOF
image:
  repository: ${VPS_IP}:3000/${PROJECT_NAME}/frontend
  tag: latest

env:
  NEXT_PUBLIC_API_URL: "http://${VPS_IP}:8080"
EOF
done

log_ok "Helm chart del frontend generado en $TF_FRONTEND/chart/"
log "  Para desplegar: helm upgrade --install ${PROJECT_NAME}-frontend $TF_FRONTEND/chart/ \\"
log "    --kubeconfig $KUBE_DIR/config-k3s -f $TF_FRONTEND/environments/dev/values.yaml"

# ===========================================================================
# BACKEND — módulo EKS
# ===========================================================================

log "Escribiendo módulo EKS..."

cat > "$TF_BACKEND/modules/eks/main.tf" << 'EOF'
data "aws_iam_policy_document" "eks_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "nodes_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.project_name}-${var.environment}-eks-cluster"
  assume_role_policy = data.aws_iam_policy_document.eks_assume_role.json
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  count      = var.attach_managed_policies ? 1 : 0
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role" "nodes" {
  name               = "${var.project_name}-${var.environment}-eks-nodes"
  assume_role_policy = data.aws_iam_policy_document.nodes_assume_role.json
}

resource "aws_iam_role_policy_attachment" "nodes_worker" {
  count      = var.attach_managed_policies ? 1 : 0
  role       = aws_iam_role.nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "nodes_cni" {
  count      = var.attach_managed_policies ? 1 : 0
  role       = aws_iam_role.nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "nodes_ecr" {
  count      = var.attach_managed_policies ? 1 : 0
  role       = aws_iam_role.nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_eks_cluster" "main" {
  name     = "${var.project_name}-${var.environment}"
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids = var.subnet_ids
  }

  # Habilita EKS access entries (RBAC vía identidad IAM) además del aws-auth
  # ConfigMap. Necesario para los access entries del controller/agente Jenkins.
  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }

  # floci no soporta UpdateClusterConfig; ignorar drift en access_config.
  lifecycle {
    ignore_changes = [access_config]
  }

  depends_on = [aws_iam_role_policy_attachment.cluster_policy]
}

# --- OIDC provider (IRSA) ---
# Permite que los ServiceAccounts del cluster (p. ej. jenkins-agent) asuman
# roles IAM mediante web identity federation.
# Floci no popula identity[0].oidc[0] ni soporta node groups; en dev se desactiva
# el data plane con enable_data_plane = false.
data "tls_certificate" "oidc" {
  count = var.enable_data_plane ? 1 : 0
  url   = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "main" {
  count           = var.enable_data_plane ? 1 : 0
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc[0].certificates[0].sha1_fingerprint]

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

resource "aws_eks_node_group" "main" {
  count           = var.enable_data_plane ? 1 : 0
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.project_name}-${var.environment}-ng"
  node_role_arn   = aws_iam_role.nodes.arn
  subnet_ids      = var.subnet_ids
  instance_types  = var.node_instance_types

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }

  depends_on = [
    aws_iam_role_policy_attachment.nodes_worker,
    aws_iam_role_policy_attachment.nodes_cni,
    aws_iam_role_policy_attachment.nodes_ecr,
  ]
}
EOF

cat > "$TF_BACKEND/modules/eks/variables.tf" << 'EOF'
variable "project_name" {
  description = "Prefijo del proyecto"
  type        = string
}

variable "environment" {
  description = "Nombre del ambiente (dev/staging/prod)"
  type        = string
}

variable "subnet_ids" {
  description = "IDs de subnets donde se desplegará el cluster"
  type        = list(string)
}

variable "kubernetes_version" {
  description = "Versión de Kubernetes"
  type        = string
  default     = "1.31"
}

variable "node_instance_types" {
  description = "Tipos de instancia para los nodos"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_desired_size" {
  description = "Número deseado de nodos"
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Número mínimo de nodos"
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Número máximo de nodos"
  type        = number
  default     = 4
}

variable "attach_managed_policies" {
  description = "Adjuntar políticas administradas de AWS a los roles (false en Floci: no existen managed policies de EKS)"
  type        = bool
  default     = true
}

variable "enable_data_plane" {
  description = "Crear node group + OIDC provider (false en Floci: no soporta CreateNodegroup ni popula el OIDC issuer del cluster)"
  type        = bool
  default     = true
}
EOF

cat > "$TF_BACKEND/modules/eks/outputs.tf" << 'EOF'
output "cluster_name" {
  description = "Nombre del cluster EKS"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "Endpoint del API server de Kubernetes"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_arn" {
  description = "ARN del cluster EKS"
  value       = aws_eks_cluster.main.arn
}

output "cluster_ca_certificate" {
  description = "Certificado CA del cluster (base64)"
  value       = aws_eks_cluster.main.certificate_authority[0].data
  sensitive   = true
}

output "cluster_oidc_issuer_url" {
  description = "URL del OIDC issuer (para IRSA); vacío cuando el data plane está desactivado (Floci)"
  value       = try(aws_eks_cluster.main.identity[0].oidc[0].issuer, "")
}

output "oidc_provider_arn" {
  description = "ARN del IAM OIDC provider del cluster (para los roles IRSA); vacío sin data plane"
  value       = try(aws_iam_openid_connect_provider.main[0].arn, "")
}

output "oidc_issuer_host" {
  description = "Host del OIDC issuer (sin https://) para las condiciones de confianza IRSA; vacío sin data plane"
  value       = try(replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", ""), "")
}

output "node_group_arn" {
  description = "ARN del node group; vacío sin data plane"
  value       = try(aws_eks_node_group.main[0].arn, "")
}
EOF

log_ok "Módulo EKS listo."

# ===========================================================================
# BACKEND — módulo RDS
# ===========================================================================

log "Escribiendo módulo RDS..."

cat > "$TF_BACKEND/modules/rds/main.tf" << 'EOF'
# Floci levanta un contenedor PostgreSQL real (postgres:16-alpine) y proxya TCP a un
# puerto del host (rango 7001-7099). Floci NO soporta CreateDBSubnetGroup ni operaciones de
# red, así que en modo floci (var.floci = true) se omite el subnet group y el instance se
# crea solo con engine/credenciales. El subnet group se mantiene para staging/prod (AWS real).
resource "aws_db_subnet_group" "main" {
  count       = var.enabled && !var.floci ? 1 : 0
  name        = "${var.project_name}-${var.environment}-rds"
  description = "Subnet group para ${var.project_name} ${var.environment}"
  subnet_ids  = var.subnet_ids

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

resource "aws_db_instance" "main" {
  count             = var.enabled ? 1 : 0
  identifier        = "${var.project_name}-${var.environment}"
  engine            = "postgres"
  engine_version    = var.engine_version
  instance_class    = var.instance_class
  allocated_storage = var.allocated_storage
  storage_encrypted = var.environment != "dev"

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = var.floci ? null : aws_db_subnet_group.main[0].name
  vpc_security_group_ids = var.vpc_security_group_ids

  multi_az            = var.multi_az
  deletion_protection = var.deletion_protection
  skip_final_snapshot = var.environment == "dev"

  backup_retention_period = var.environment == "dev" ? 0 : 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }

  # floci no soporta AddTagsToResource para RDS; ignorar drift en tags.
  lifecycle {
    ignore_changes = [tags, tags_all]
  }
}
EOF

cat > "$TF_BACKEND/modules/rds/variables.tf" << 'EOF'
variable "project_name" {
  description = "Prefijo del proyecto"
  type        = string
}

variable "environment" {
  description = "Nombre del ambiente (dev/staging/prod)"
  type        = string
}

variable "subnet_ids" {
  description = "IDs de subnets para el DB subnet group"
  type        = list(string)
}

variable "vpc_security_group_ids" {
  description = "IDs de security groups con acceso a RDS"
  type        = list(string)
}

variable "db_name" {
  description = "Nombre de la base de datos inicial"
  type        = string
}

variable "db_username" {
  description = "Usuario administrador de la base de datos"
  type        = string
}

variable "db_password" {
  description = "Contraseña del usuario administrador"
  type        = string
  sensitive   = true
}

variable "engine_version" {
  description = "Versión del motor PostgreSQL"
  type        = string
  default     = "16.3"
}

variable "instance_class" {
  description = "Tipo de instancia RDS"
  type        = string
  default     = "db.t3.micro"
}

variable "allocated_storage" {
  description = "Almacenamiento asignado en GB"
  type        = number
  default     = 20
}

variable "multi_az" {
  description = "Habilitar despliegue Multi-AZ"
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Proteger la instancia contra eliminación accidental"
  type        = bool
  default     = false
}

variable "enabled" {
  description = "Crear recursos RDS"
  type        = bool
  default     = true
}

variable "floci" {
  description = "Modo floci: omite subnet group y red no soportados; crea solo el DB instance"
  type        = bool
  default     = false
}
EOF

cat > "$TF_BACKEND/modules/rds/outputs.tf" << 'EOF'
output "endpoint" {
  description = "Endpoint de conexión a RDS"
  value       = try(aws_db_instance.main[0].endpoint, "")
}

output "port" {
  description = "Puerto de conexión a RDS"
  value       = try(aws_db_instance.main[0].port, null)
}

output "db_name" {
  description = "Nombre de la base de datos"
  value       = try(aws_db_instance.main[0].db_name, "")
}

output "identifier" {
  description = "Identificador de la instancia RDS"
  value       = try(aws_db_instance.main[0].identifier, "")
}

output "arn" {
  description = "ARN de la instancia RDS"
  value       = try(aws_db_instance.main[0].arn, "")
}
EOF

log_ok "Módulo RDS listo."

# ===========================================================================
# BACKEND — módulo IAM
# ===========================================================================

log "Escribiendo módulo IAM..."

cat > "$TF_BACKEND/modules/iam/main.tf" << 'EOF'
data "aws_iam_policy_document" "ecs_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_task_execution" {
  name               = "${var.project_name}-${var.environment}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
}

resource "aws_iam_role" "ecs_task" {
  name               = "${var.project_name}-${var.environment}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
}

resource "aws_iam_role_policy_attachment" "ecs_execution_managed" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_policy" "secrets_read" {
  name        = "${var.project_name}-${var.environment}-secrets-read"
  description = "Allow reading Secrets Manager secrets"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = "arn:aws:secretsmanager:*:*:secret:/${var.environment}/*"
    }]
  })

  # Floci ignora el atributo description al crear la política; ignorar el drift
  # evita reemplazos innecesarios en cada apply.
  lifecycle {
    ignore_changes = [description, tags_all]
  }
}

resource "aws_iam_role_policy_attachment" "task_secrets" {
  role       = aws_iam_role.ecs_task.name
  policy_arn = aws_iam_policy.secrets_read.arn
}

# ECR pull policy eliminada: el registry de imágenes es Gitea Package Registry (OCI nativo).
# Los pods de K3s autentican con imagePullSecrets (Secret kubernetes.io/dockerconfigjson).
# Para staging/prod con ECR real, agregar la política aws_iam_policy.ecr_pull aquí.
EOF

cat > "$TF_BACKEND/modules/iam/variables.tf" << 'EOF'
variable "project_name" {
  description = "Prefijo del proyecto"
  type        = string
}

variable "environment" {
  description = "Nombre del ambiente (dev/staging/prod)"
  type        = string
}
EOF

cat > "$TF_BACKEND/modules/iam/outputs.tf" << 'EOF'
output "task_execution_role_arn" {
  description = "ARN del ECS task execution role"
  value       = aws_iam_role.ecs_task_execution.arn
}

output "task_role_arn" {
  description = "ARN del ECS task role"
  value       = aws_iam_role.ecs_task.arn
}

output "secrets_read_policy_arn" {
  description = "ARN de la política de lectura de Secrets Manager"
  value       = aws_iam_policy.secrets_read.arn
}

output "secrets_read_policy_arn_task" {
  description = "ARN de la política de lectura de Secrets Manager (task role)"
  value       = aws_iam_policy.secrets_read.arn
}
EOF

log_ok "Módulo IAM listo."

# ===========================================================================
# BACKEND — módulo Cognito
# ===========================================================================

log "Escribiendo módulo Cognito..."

cat > "$TF_BACKEND/modules/cognito/main.tf" << 'EOF'
resource "aws_cognito_user_pool" "main" {
  name = "${var.project_name}-${var.environment}"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length                   = 8
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 7
  }

  mfa_configuration = var.environment == "dev" ? "OFF" : "OPTIONAL"

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

resource "aws_cognito_user_pool_client" "app_client" {
  name         = "${var.project_name}-${var.environment}-client"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret = false

  # Floci devuelve estos atributos en cero/vacío tras el apply, lo que produce un
  # error "Provider produced inconsistent result" (comprobación en tiempo de apply
  # que ignore_changes NO evita). En el emulador se omite toda la configuración
  # OAuth/token y se crea un client mínimo; en AWS real se configura completa.
  allowed_oauth_flows_user_pool_client = var.emulator ? null : true
  allowed_oauth_flows                  = var.emulator ? null : ["implicit", "code"]
  allowed_oauth_scopes                 = var.emulator ? null : ["email", "openid", "profile"]

  callback_urls = var.emulator ? null : var.callback_urls
  logout_urls   = var.emulator ? null : var.logout_urls

  supported_identity_providers = var.emulator ? null : ["COGNITO"]

  access_token_validity  = var.emulator ? null : 1
  id_token_validity      = var.emulator ? null : 1
  refresh_token_validity = var.emulator ? null : 30

  dynamic "token_validity_units" {
    for_each = var.emulator ? [] : [1]
    content {
      access_token  = "hours"
      id_token      = "hours"
      refresh_token = "days"
    }
  }
}

# CreateUserPoolDomain no está soportado en Floci; se omite en dev con enable_domain = false.
resource "aws_cognito_user_pool_domain" "main" {
  count        = var.enable_domain ? 1 : 0
  domain       = "${var.project_name}-${var.environment}"
  user_pool_id = aws_cognito_user_pool.main.id
}
EOF

cat > "$TF_BACKEND/modules/cognito/variables.tf" << 'EOF'
variable "project_name" {
  description = "Prefijo del proyecto"
  type        = string
}

variable "environment" {
  description = "Nombre del ambiente (dev/staging/prod)"
  type        = string
}

variable "callback_urls" {
  description = "URLs de callback OAuth2"
  type        = list(string)
  default     = ["http://localhost:3000/api/auth/callback/cognito"]
}

variable "logout_urls" {
  description = "URLs de logout OAuth2"
  type        = list(string)
  default     = ["http://localhost:3000"]
}

variable "enable_domain" {
  description = "Crear el dominio del User Pool (false en Floci: CreateUserPoolDomain no soportado)"
  type        = bool
  default     = true
}

variable "emulator" {
  description = "Crear un app client mínimo sin OAuth/token config (true en Floci: devuelve atributos inconsistentes tras el apply)"
  type        = bool
  default     = false
}
EOF

cat > "$TF_BACKEND/modules/cognito/outputs.tf" << 'EOF'
output "user_pool_id" {
  description = "ID del User Pool"
  value       = aws_cognito_user_pool.main.id
}

output "user_pool_arn" {
  description = "ARN del User Pool"
  value       = aws_cognito_user_pool.main.arn
}

output "user_pool_endpoint" {
  description = "Endpoint del User Pool (usado como issuer en API Gateway)"
  value       = "https://${aws_cognito_user_pool.main.endpoint}"
}

output "client_id" {
  description = "ID del App Client"
  value       = aws_cognito_user_pool_client.app_client.id
}

output "jwks_uri" {
  description = "URL del JWKS para validación de tokens"
  value       = "https://${aws_cognito_user_pool.main.endpoint}/.well-known/jwks.json"
}
EOF

log_ok "Módulo Cognito listo."

# ===========================================================================
# BACKEND — módulo API Gateway
# ===========================================================================

log "Escribiendo módulo API Gateway..."

cat > "$TF_BACKEND/modules/api-gateway/main.tf" << 'EOF'
resource "aws_cloudwatch_log_group" "api_logs" {
  name              = "/aws/apigateway/${var.project_name}-${var.environment}"
  retention_in_days = 7
}

resource "aws_apigatewayv2_api" "main" {
  name          = "${var.project_name}-${var.environment}"
  protocol_type = "HTTP"

  cors_configuration {
    allow_headers = ["Authorization", "Content-Type"]
    allow_methods = ["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"]
    allow_origins = var.cors_allow_origins
    max_age       = 300
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

resource "aws_apigatewayv2_authorizer" "cognito_jwt" {
  api_id           = aws_apigatewayv2_api.main.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "cognito-jwt"

  jwt_configuration {
    issuer   = var.cognito_user_pool_endpoint
    audience = [var.cognito_client_id]
  }
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_logs.arn
    format = jsonencode({
      requestId               = "$context.requestId"
      ip                      = "$context.identity.sourceIp"
      requestTime             = "$context.requestTime"
      httpMethod              = "$context.httpMethod"
      routeKey                = "$context.routeKey"
      status                  = "$context.status"
      protocol                = "$context.protocol"
      responseLength          = "$context.responseLength"
      integrationErrorMessage = "$context.integrationErrorMessage"
    })
  }
}

resource "aws_apigatewayv2_route" "health" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "GET /health"
}

resource "aws_apigatewayv2_route" "api_protected" {
  api_id             = aws_apigatewayv2_api.main.id
  route_key          = "ANY /api/{proxy+}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito_jwt.id
}
EOF

cat > "$TF_BACKEND/modules/api-gateway/variables.tf" << 'EOF'
variable "project_name" {
  description = "Prefijo del proyecto"
  type        = string
}

variable "environment" {
  description = "Nombre del ambiente (dev/staging/prod)"
  type        = string
}

variable "cognito_user_pool_endpoint" {
  description = "Endpoint del User Pool de Cognito (issuer JWT)"
  type        = string
}

variable "cognito_client_id" {
  description = "App Client ID de Cognito (audience JWT)"
  type        = string
}

variable "cors_allow_origins" {
  description = "Orígenes permitidos por CORS"
  type        = list(string)
  default     = ["http://localhost:3000"]
}
EOF

cat > "$TF_BACKEND/modules/api-gateway/outputs.tf" << 'EOF'
output "api_endpoint" {
  description = "URL base del API Gateway"
  value       = aws_apigatewayv2_api.main.api_endpoint
}

output "authorizer_id" {
  description = "ID del JWT authorizer"
  value       = aws_apigatewayv2_authorizer.cognito_jwt.id
}

output "stage_name" {
  description = "Nombre del stage desplegado"
  value       = aws_apigatewayv2_stage.default.name
}

output "api_id" {
  description = "ID del API Gateway"
  value       = aws_apigatewayv2_api.main.id
}
EOF

log_ok "Módulo API Gateway listo."

# ===========================================================================
# BACKEND — módulo Secrets Manager
# ===========================================================================

log "Escribiendo módulo Secrets Manager..."

cat > "$TF_BACKEND/modules/secrets-manager/main.tf" << 'EOF'
resource "aws_secretsmanager_secret" "service_env" {
  for_each = toset(var.services)

  name        = "/${var.environment}/${each.key}/env"
  description = "Variables de entorno para el microservicio ${each.key}"

  tags = {
    Environment = var.environment
    Service     = each.key
  }
}

resource "aws_secretsmanager_secret_version" "service_env" {
  for_each = toset(var.services)

  secret_id = aws_secretsmanager_secret.service_env[each.key].id
  secret_string = jsonencode({
    DB_URL       = "jdbc:postgresql://localhost:5432/${each.key}"
    DB_USER      = "change_me"
    DB_PASSWORD  = "change_me"
    RABBITMQ_URL = "amqp://localhost:5672"
  })
}
EOF

cat > "$TF_BACKEND/modules/secrets-manager/variables.tf" << 'EOF'
variable "environment" {
  description = "Nombre del ambiente (dev/staging/prod)"
  type        = string
}

variable "services" {
  description = "Lista de microservicios del proyecto"
  type        = list(string)
}
EOF

cat > "$TF_BACKEND/modules/secrets-manager/outputs.tf" << 'EOF'
output "secret_arns" {
  description = "Mapa de service_name => secret_arn"
  value       = { for k, v in aws_secretsmanager_secret.service_env : k => v.arn }
}

output "secret_names" {
  description = "Mapa de service_name => secret_name"
  value       = { for k, v in aws_secretsmanager_secret.service_env : k => v.name }
}
EOF

log_ok "Módulo Secrets Manager listo."

# ===========================================================================
# BACKEND — módulo ECR
# ===========================================================================

log "Escribiendo módulo ECR..."

cat > "$TF_BACKEND/modules/ecr/main.tf" << 'EOF'
locals {
  mutability = var.environment == "prod" ? "IMMUTABLE" : "MUTABLE"
  scan       = var.environment != "dev"
}

resource "aws_ecr_repository" "service" {
  for_each = toset(var.services)

  name                 = "${var.project_name}/${each.key}"
  image_tag_mutability = local.mutability

  image_scanning_configuration {
    scan_on_push = local.scan
  }

  tags = {
    Environment = var.environment
    Service     = each.key
  }
}

resource "aws_ecr_lifecycle_policy" "service" {
  for_each   = toset(var.services)
  repository = aws_ecr_repository.service[each.key].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Eliminar imágenes sin tag con más de 1 día"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Retener solo las últimas 10 imágenes tagged"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v"]
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}
EOF

cat > "$TF_BACKEND/modules/ecr/variables.tf" << 'EOF'
variable "project_name" {
  description = "Prefijo del proyecto"
  type        = string
}

variable "environment" {
  description = "Nombre del ambiente (dev/staging/prod)"
  type        = string
}

variable "services" {
  description = "Lista de microservicios del proyecto"
  type        = list(string)
}
EOF

cat > "$TF_BACKEND/modules/ecr/outputs.tf" << 'EOF'
output "repository_urls" {
  description = "Mapa de service_name => repository_url"
  value       = { for k, v in aws_ecr_repository.service : k => v.repository_url }
}

output "registry_id" {
  description = "ID del registro ECR"
  value       = try(values(aws_ecr_repository.service)[0].registry_id, null)
}
EOF

log_ok "Módulo ECR listo."


# ===========================================================================
# BACKEND — módulo Jenkins (controller EC2 + Docker, agentes en EKS)
# ===========================================================================
#
# Controller: contenedor Docker en una instancia EC2 singleton (ASG 1/1/1) con
# JENKINS_HOME persistido en un volumen EBS. Expuesto vía ALB.
# Agentes: pods efímeros en el cluster EKS (Kubernetes plugin). La autenticación
# de kaniko (push ECR) y del deploy (helm/kubectl) usa IRSA sobre el
# ServiceAccount 'jenkins-agent'. El acceso del controller (lanzar pods) y del
# agente (desplegar) al API server se concede con EKS access entries.

log "Escribiendo módulo Jenkins (controller EC2 + agentes EKS)..."

cat > "$TF_BACKEND/modules/jenkins/main.tf" << 'EOF'
data "aws_caller_identity" "current" {}

locals {
  ecr_registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

# --- Security Groups ---

resource "aws_security_group" "alb" {
  name        = "${var.project_name}-${var.environment}-jenkins-alb"
  description = "Security group para el ALB de Jenkins"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

resource "aws_security_group" "jenkins_ec2" {
  name        = "${var.project_name}-${var.environment}-jenkins-ec2"
  description = "Security group para la instancia EC2 del controller Jenkins"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
    description     = "UI Jenkins desde ALB"
  }

  ingress {
    from_port   = 50000
    to_port     = 50000
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "Agentes JNLP"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

# --- EBS (persistencia de JENKINS_HOME) ---
# La AZ del volumen se deriva de subnet_ids[0] para coincidir con la instancia EC2.

data "aws_subnet" "jenkins_primary" {
  count = var.availability_zone == "" ? 1 : 0
  id    = var.subnet_ids[0]
}

locals {
  jenkins_az = var.availability_zone != "" ? var.availability_zone : data.aws_subnet.jenkins_primary[0].availability_zone
}

resource "aws_ebs_volume" "jenkins_home" {
  availability_zone = local.jenkins_az
  size              = var.volume_size_gb
  type              = var.volume_type
  encrypted         = true

  tags = {
    Name        = "${var.project_name}-${var.environment}-jenkins-home"
    Environment = var.environment
    Project     = var.project_name
  }

  lifecycle {
    prevent_destroy = true
  }
}

# --- IAM para la instancia EC2 del controller ---

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "jenkins_ec2" {
  name               = "${var.project_name}-${var.environment}-jenkins-ec2"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

# Permite a SSM administrar la instancia (sesiones sin SSH abierto).
# attach_ssm_policy = false en Floci: AmazonSSMManagedInstanceCore no existe.
resource "aws_iam_role_policy_attachment" "jenkins_ec2_ssm" {
  count      = var.attach_ssm_policy ? 1 : 0
  role       = aws_iam_role.jenkins_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_policy" "jenkins_ec2" {
  name        = "${var.project_name}-${var.environment}-jenkins-ec2"
  description = "Adjuntar el EBS de JENKINS_HOME y resolver el cluster EKS (kubeconfig)"

  lifecycle {
    ignore_changes = [description, tags_all]
  }

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AttachJenkinsHome"
        Effect   = "Allow"
        Action   = ["ec2:AttachVolume", "ec2:DescribeVolumes", "ec2:DescribeVolumeStatus"]
        Resource = "*"
      },
      {
        # El Kubernetes plugin usa esta identidad para 'aws eks get-token' y
        # lanzar los pods agente; el acceso RBAC lo concede el access entry.
        Sid      = "DescribeEksCluster"
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "jenkins_ec2" {
  role       = aws_iam_role.jenkins_ec2.name
  policy_arn = aws_iam_policy.jenkins_ec2.arn
}

resource "aws_iam_instance_profile" "jenkins_ec2" {
  name = "${var.project_name}-${var.environment}-jenkins-ec2"
  role = aws_iam_role.jenkins_ec2.name
}

# --- IAM IRSA para los pods agente (ServiceAccount jenkins-agent) ---
# Federación OIDC del cluster EKS: solo el SA jenkins:jenkins-agent puede asumir
# este rol. kaniko lo usa para push a ECR; el deploy para 'aws eks get-token'.

data "aws_iam_policy_document" "jenkins_agent_assume_role" {
  count = var.enable_compute ? 1 : 0
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.eks_oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.eks_oidc_issuer_host}:sub"
      values   = ["system:serviceaccount:${var.agent_namespace}:jenkins-agent"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.eks_oidc_issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "jenkins_agent" {
  count              = var.enable_compute ? 1 : 0
  name               = "${var.project_name}-${var.environment}-jenkins-agent"
  assume_role_policy = data.aws_iam_policy_document.jenkins_agent_assume_role[0].json
}

resource "aws_iam_policy" "jenkins_agent" {
  count       = var.enable_compute ? 1 : 0
  name        = "${var.project_name}-${var.environment}-jenkins-agent"
  description = "Permisos del agente: push/pull ECR (kaniko), leer secrets y describir EKS (deploy)"

  lifecycle {
    ignore_changes = [description, tags_all]
  }

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ECRAuth"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "ECRPushPull"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload"
        ]
        Resource = "*"
      },
      {
        Sid    = "SecretsManager"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = "*"
      },
      {
        # Necesario para 'aws eks update-kubeconfig' antes de helm/kubectl;
        # el acceso RBAC al namespace lo concede el access entry del agente.
        Sid      = "EKSDescribe"
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "jenkins_agent" {
  count      = var.enable_compute ? 1 : 0
  role       = aws_iam_role.jenkins_agent[0].name
  policy_arn = aws_iam_policy.jenkins_agent[0].arn
}

# --- EKS access entries (RBAC vía identidad AWS) ---
# Floci no soporta CreateAccessEntry; en dev se desactivan con enable_compute = false.
# Controller: crea/borra los pods agente en el namespace 'jenkins'.
resource "aws_eks_access_entry" "jenkins_controller" {
  count         = var.enable_compute ? 1 : 0
  cluster_name  = var.eks_cluster_name
  principal_arn = aws_iam_role.jenkins_ec2.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "jenkins_controller" {
  count         = var.enable_compute ? 1 : 0
  cluster_name  = var.eks_cluster_name
  principal_arn = aws_iam_role.jenkins_ec2.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = [var.agent_namespace]
  }

  depends_on = [aws_eks_access_entry.jenkins_controller]
}

# Agente: despliega (helm/kubectl) en el namespace de la aplicación del ambiente.
resource "aws_eks_access_entry" "jenkins_agent" {
  count         = var.enable_compute ? 1 : 0
  cluster_name  = var.eks_cluster_name
  principal_arn = aws_iam_role.jenkins_agent[0].arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "jenkins_agent" {
  count         = var.enable_compute ? 1 : 0
  cluster_name  = var.eks_cluster_name
  principal_arn = aws_iam_role.jenkins_agent[0].arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = [var.environment]
  }

  depends_on = [aws_eks_access_entry.jenkins_agent]
}

# --- Launch Template + ASG (instancia EC2 singleton del controller) ---
# Floci no soporta CreateLaunchTemplate; en dev se desactiva con enable_compute = false.

resource "aws_launch_template" "jenkins" {
  count         = var.enable_compute ? 1 : 0
  name_prefix   = "${var.project_name}-${var.environment}-jenkins-"
  image_id      = var.ami_id
  instance_type = var.instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.jenkins_ec2.arn
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.jenkins_ec2.id]
  }

  # $INSTANCE_ID/$REGION/$DEVICE/$i/$PRIVATE_IP son variables bash (runtime en EC2).
  # ${...} son interpolaciones Terraform expandidas en apply time.
  user_data = base64encode(<<-USERDATA
    #!/bin/bash
    set -euxo pipefail

    # --- Herramientas: Docker, aws-cli v2, kubectl ---
    if command -v dnf &>/dev/null; then
      dnf install -y docker unzip
    else
      amazon-linux-extras install -y docker && yum install -y unzip
    fi
    systemctl enable --now docker

    if ! command -v aws &>/dev/null; then
      curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
      unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install
    fi

    curl -fsSL -o /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/v1.31.0/bin/linux/amd64/kubectl"
    chmod +x /usr/local/bin/kubectl

    # --- Adjuntar y montar el EBS de JENKINS_HOME ---
    INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
    REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
    PRIVATE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
    VOLUME_ID="${aws_ebs_volume.jenkins_home.id}"

    aws ec2 attach-volume \
      --volume-id "$VOLUME_ID" \
      --instance-id "$INSTANCE_ID" \
      --device /dev/xvdf \
      --region "$REGION"

    for i in $(seq 1 30); do
      { [ -e /dev/xvdf ] || [ -e /dev/nvme1n1 ]; } && break
      sleep 2
    done

    DEVICE=$([ -e /dev/nvme1n1 ] && echo /dev/nvme1n1 || echo /dev/xvdf)

    if ! blkid "$DEVICE" &>/dev/null; then
      mkfs -t ext4 "$DEVICE"
    fi

    mkdir -p /var/jenkins_home
    mount "$DEVICE" /var/jenkins_home
    grep -q /var/jenkins_home /etc/fstab || \
      echo "$DEVICE /var/jenkins_home ext4 defaults,nofail 0 2" >> /etc/fstab

    # --- kubeconfig para el Kubernetes plugin (exec auth vía rol de la EC2) ---
    mkdir -p /var/jenkins_home/.kube
    aws eks update-kubeconfig \
      --name "${var.eks_cluster_name}" \
      --region "$REGION" \
      --kubeconfig /var/jenkins_home/.kube/config
    chown -R 1000:1000 /var/jenkins_home

    # --- Arrancar el controller Jenkins ---
    # var.jenkins_image deberia ser la imagen propia con JCasC + plugins horneados
    # (jenkins-shared-library/docker). Las variables de entorno alimentan las
    # interpolaciones del jenkins.yaml (JCasC).
    docker run -d --name jenkins --restart unless-stopped \
      -p 8080:8080 -p 50000:50000 \
      -v /var/jenkins_home:/var/jenkins_home \
      -e JAVA_OPTS="-Djenkins.install.runSetupWizard=false" \
      -e ECR_REGISTRY="${local.ecr_registry}" \
      -e EKS_CLUSTER_NAME="${var.eks_cluster_name}" \
      -e EKS_API_SERVER="${var.eks_cluster_endpoint}" \
      -e AWS_REGION="$REGION" \
      -e JENKINS_URL="http://$PRIVATE_IP:8080" \
      -e JENKINS_TUNNEL="$PRIVATE_IP:50000" \
      -e SHARED_LIBRARY_REPO="${var.shared_library_repo}" \
      -e SONAR_URL="${var.sonar_url}" \
      -e SONAR_TOKEN="${var.sonar_token}" \
      -e SLACK_TEAM="${var.slack_team}" \
      -e SLACK_TOKEN="${var.slack_token}" \
      -e VERCEL_TOKEN="${var.vercel_token}" \
      -e VERCEL_ORG_ID="${var.vercel_org_id}" \
      -e VERCEL_PROJECT_ID="${var.vercel_project_id}" \
      -e GITOPS_GIT_USERNAME="${var.gitops_git_username}" \
      -e GITOPS_GIT_TOKEN="${var.gitops_git_token}" \
      "${var.jenkins_image}"
  USERDATA
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${var.project_name}-${var.environment}-jenkins"
      Environment = var.environment
      Project     = var.project_name
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Singleton: desired/min/max = 1. Fijado a subnet_ids[0] para que la AZ
# coincida con el volumen EBS.
resource "aws_autoscaling_group" "jenkins" {
  count               = var.enable_compute ? 1 : 0
  name                = "${var.project_name}-${var.environment}-jenkins"
  vpc_zone_identifier = [var.subnet_ids[0]]
  desired_capacity    = 1
  min_size            = 1
  max_size            = 1

  launch_template {
    id      = aws_launch_template.jenkins[0].id
    version = "$Latest"
  }

  tag {
    key                 = "AmazonECSManaged"
    value               = ""
    propagate_at_launch = true
  }

  tag {
    key                 = "Environment"
    value               = var.environment
    propagate_at_launch = true
  }

  lifecycle {
    ignore_changes = [desired_capacity]
  }
}

# --- ALB ---
# Floci no enruta ELBv2; en dev se desactiva con enable_compute = false.

resource "aws_lb" "jenkins" {
  count              = var.enable_compute ? 1 : 0
  name               = "${var.project_name}-${var.environment}-jenkins"
  internal           = var.alb_internal
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

resource "aws_lb_target_group" "jenkins" {
  count       = var.enable_compute ? 1 : 0
  name        = "${var.project_name}-${var.environment}-jenkins"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    path                = "/login"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 10
    interval            = 30
    matcher             = "200"
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

resource "aws_lb_listener" "jenkins" {
  count             = var.enable_compute ? 1 : 0
  load_balancer_arn = aws_lb.jenkins[0].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.jenkins[0].arn
  }
}

# Registra el ASG como target del ALB (target_type = instance).
resource "aws_autoscaling_attachment" "jenkins" {
  count                  = var.enable_compute ? 1 : 0
  autoscaling_group_name = aws_autoscaling_group.jenkins[0].name
  lb_target_group_arn    = aws_lb_target_group.jenkins[0].arn
}
EOF

cat > "$TF_BACKEND/modules/jenkins/variables.tf" << 'EOF'
variable "project_name" {
  description = "Prefijo del proyecto"
  type        = string
}

variable "environment" {
  description = "Nombre del ambiente (dev/staging/prod)"
  type        = string
}

variable "vpc_id" {
  description = "ID de la VPC donde se despliega Jenkins"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR de la VPC (regla de entrada para agentes JNLP port 50000)"
  type        = string
}

variable "subnet_ids" {
  description = "Subnets privadas; subnet_ids[0] determina la AZ del volumen EBS"
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Subnets públicas para el ALB"
  type        = list(string)
}

variable "ami_id" {
  description = "AMI base para la instancia EC2 del controller (Amazon Linux 2023 con Docker disponible vía dnf)"
  type        = string
}

variable "instance_type" {
  description = "Tipo de instancia EC2 para el controller Jenkins"
  type        = string
  default     = "t3.medium"
}

variable "volume_size_gb" {
  description = "Tamaño del volumen EBS para JENKINS_HOME en GB"
  type        = number
  default     = 30
}

variable "volume_type" {
  description = "Tipo de volumen EBS"
  type        = string
  default     = "gp3"
}

variable "aws_region" {
  description = "Región AWS"
  type        = string
  default     = "us-east-1"
}

variable "availability_zone" {
  description = "Availability Zone (se infiere de subnet_ids[0] si se omite; requerido con floci)"
  type        = string
  default     = ""
}

variable "jenkins_image" {
  description = "Imagen Docker del controller (recomendado: imagen propia con JCasC + plugins en ECR)"
  type        = string
  default     = "jenkins/jenkins:lts-jdk21"
}

# --- Integración con EKS (agentes + RBAC) ---

variable "eks_cluster_name" {
  description = "Nombre del cluster EKS donde corren los agentes y se despliega la aplicación"
  type        = string
}

variable "eks_cluster_endpoint" {
  description = "Endpoint del API server de EKS (serverUrl del Kubernetes cloud en JCasC)"
  type        = string
}

variable "shared_library_repo" {
  description = "URL git del repositorio jenkins-shared-library (Global Pipeline Library)"
  type        = string
  default     = ""
}

variable "sonar_url" {
  description = "URL del servidor SonarQube (ej. http://sonarqube:9000)"
  type        = string
  default     = ""
}

variable "sonar_token" {
  description = "Token de autenticación de SonarQube"
  type        = string
  sensitive   = true
  default     = ""
}

variable "slack_team" {
  description = "Workspace de Slack (subdominio de slack.com)"
  type        = string
  default     = ""
}

variable "slack_token" {
  description = "Token del bot de Slack para el canal #cicd"
  type        = string
  sensitive   = true
  default     = ""
}

variable "vercel_token" {
  description = "Token de servicio de Vercel"
  type        = string
  sensitive   = true
  default     = ""
}

variable "vercel_org_id" {
  description = "ID de la organización en Vercel"
  type        = string
  default     = ""
}

variable "vercel_project_id" {
  description = "ID del proyecto __PROJECT_NAME__-web en Vercel"
  type        = string
  default     = ""
}

variable "gitops_git_username" {
  description = "Usuario git con permiso de push (para bumpImageTag)"
  type        = string
  default     = ""
}

variable "gitops_git_token" {
  description = "Token del usuario git (para bumpImageTag)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "eks_oidc_provider_arn" {
  description = "ARN del IAM OIDC provider del cluster EKS (para IRSA del agente)"
  type        = string
}

variable "eks_oidc_issuer_host" {
  description = "Host del OIDC issuer del cluster (issuer sin el prefijo https://), para las condiciones IRSA"
  type        = string
}

variable "agent_namespace" {
  description = "Namespace de Kubernetes donde el controller lanza los pods agente"
  type        = string
  default     = "jenkins"
}

variable "allowed_cidr_blocks" {
  description = "CIDRs con acceso HTTP/HTTPS a la UI de Jenkins vía ALB"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "alb_internal" {
  description = "Si true el ALB es interno (solo accesible desde la VPC)"
  type        = bool
  default     = false
}

variable "attach_ssm_policy" {
  description = "Adjuntar AmazonSSMManagedInstanceCore al rol EC2 (false en Floci: managed policy no existe)"
  type        = bool
  default     = true
}

variable "enable_compute" {
  description = "Crear el cómputo EC2/ELB + access entries EKS + IRSA del agente (false en Floci: no soporta launch templates, ELBv2 ni access entries)"
  type        = bool
  default     = true
}
EOF

cat > "$TF_BACKEND/modules/jenkins/outputs.tf" << 'EOF'
output "jenkins_url" {
  description = "URL de acceso a la UI de Jenkins vía ALB; vacío sin cómputo (Floci)"
  value       = try("http://${aws_lb.jenkins[0].dns_name}", "")
}

output "alb_dns_name" {
  description = "DNS name del ALB de Jenkins; vacío sin cómputo (Floci)"
  value       = try(aws_lb.jenkins[0].dns_name, "")
}

output "agent_role_arn" {
  description = "ARN del IAM role IRSA del agente; vacío sin cómputo (Floci)"
  value       = try(aws_iam_role.jenkins_agent[0].arn, "")
}

output "controller_role_arn" {
  description = "ARN del IAM role de la instancia EC2 del controller (mapeado en el access entry de EKS)"
  value       = aws_iam_role.jenkins_ec2.arn
}

output "ebs_volume_id" {
  description = "ID del volumen EBS que persiste JENKINS_HOME"
  value       = aws_ebs_volume.jenkins_home.id
}

output "ec2_security_group_id" {
  description = "ID del security group de la instancia EC2 Jenkins"
  value       = aws_security_group.jenkins_ec2.id
}
EOF

log_ok "Módulo Jenkins listo."

# ===========================================================================
# BACKEND — módulo MSK (Amazon Managed Streaming for Apache Kafka)
# ===========================================================================

log "Escribiendo módulo MSK..."

cat > "$TF_BACKEND/modules/msk/main.tf" << 'EOF'
locals {
  replication_factor  = var.number_of_broker_nodes > 1 ? 2 : 1
  min_insync_replicas = var.environment == "prod" ? 2 : 1
  log_retention_days  = var.environment == "dev" ? 7 : 30
}

# Floci orquesta un contenedor Redpanda real (compatible con la API de Kafka). El puerto
# del broker se mapea dinámicamente; obtenerlo vía GetBootstrapBrokers (output msk_bootstrap_brokers).
# Floci solo soporta CreateCluster/GetBootstrapBrokers: NO CreateConfiguration, ni logging_info,
# ni open_monitoring. En modo floci (var.floci = true) se crea el cluster con la config mínima
# (broker_node_group_info) y se omite lo demás. El SG sí se crea (floci soporta EC2 SGs) porque
# broker_node_group_info.security_groups es obligatorio en el provider. Staging/prod conservan todo.
resource "aws_security_group" "msk" {
  count       = var.enabled ? 1 : 0
  name        = "${var.project_name}-${var.environment}-msk"
  description = "Security group para el cluster MSK"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 9092
    to_port     = 9092
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "Kafka plaintext desde la VPC"
  }

  ingress {
    from_port   = 9094
    to_port     = 9094
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "Kafka TLS desde la VPC"
  }

  ingress {
    from_port   = 9096
    to_port     = 9096
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "Kafka SASL/SCRAM desde la VPC"
  }

  ingress {
    from_port   = 2181
    to_port     = 2181
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "ZooKeeper desde la VPC"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

resource "aws_cloudwatch_log_group" "msk_broker" {
  count             = var.enabled && !var.floci ? 1 : 0
  name              = "/aws/msk/${var.project_name}-${var.environment}/broker"
  retention_in_days = local.log_retention_days

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

resource "aws_msk_configuration" "main" {
  count          = var.enabled && !var.floci ? 1 : 0
  name           = "${var.project_name}-${var.environment}"
  kafka_versions = [var.kafka_version]
  description    = "Configuración broker MSK para ${var.project_name} ${var.environment}"

  server_properties = <<-PROPS
auto.create.topics.enable=false
default.replication.factor=${local.replication_factor}
min.insync.replicas=${local.min_insync_replicas}
num.partitions=3
log.retention.hours=${var.environment == "dev" ? 24 : 168}
PROPS
}

resource "aws_msk_cluster" "main" {
  count                  = var.enabled ? 1 : 0
  cluster_name           = "${var.project_name}-${var.environment}"
  kafka_version          = var.kafka_version
  number_of_broker_nodes = var.number_of_broker_nodes

  broker_node_group_info {
    # Un broker por subnet; las subnets deben estar en AZs distintas.
    instance_type   = var.broker_instance_type
    client_subnets  = slice(var.subnet_ids, 0, var.number_of_broker_nodes)
    security_groups = [aws_security_group.msk[0].id]
    storage_info {
      ebs_storage_info {
        volume_size = var.broker_ebs_volume_size
      }
    }
  }

  dynamic "encryption_info" {
    for_each = var.floci ? [] : [1]
    content {
      encryption_in_transit {
        client_broker = var.environment == "dev" ? "TLS_PLAINTEXT" : "TLS"
        in_cluster    = true
      }
    }
  }

  dynamic "configuration_info" {
    for_each = var.floci ? [] : [1]
    content {
      arn      = aws_msk_configuration.main[0].arn
      revision = aws_msk_configuration.main[0].latest_revision
    }
  }

  dynamic "logging_info" {
    for_each = var.floci ? [] : [1]
    content {
      broker_logs {
        cloudwatch_logs {
          enabled   = true
          log_group = aws_cloudwatch_log_group.msk_broker[0].name
        }
      }
    }
  }

  dynamic "open_monitoring" {
    for_each = var.floci ? [] : [1]
    content {
      prometheus {
        jmx_exporter { enabled_in_broker = true }
        node_exporter { enabled_in_broker = true }
      }
    }
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

# Política IAM para producir/consumir desde microservicios vía autenticación IAM.
resource "aws_iam_policy" "msk_access" {
  count       = var.enabled ? 1 : 0
  name        = "${var.project_name}-${var.environment}-msk-access"
  description = "Permite a los microservicios producir y consumir en el cluster MSK"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "MSKClusterConnect"
        Effect = "Allow"
        Action = [
          "kafka-cluster:Connect",
          "kafka-cluster:DescribeCluster"
        ]
        Resource = aws_msk_cluster.main[0].arn
      },
      {
        Sid    = "MSKTopicReadWrite"
        Effect = "Allow"
        Action = [
          "kafka-cluster:CreateTopic",
          "kafka-cluster:DescribeTopic",
          "kafka-cluster:WriteData",
          "kafka-cluster:ReadData"
        ]
        Resource = "arn:aws:kafka:*:*:topic/${aws_msk_cluster.main[0].cluster_name}/*/*"
      },
      {
        Sid    = "MSKConsumerGroup"
        Effect = "Allow"
        Action = [
          "kafka-cluster:AlterGroup",
          "kafka-cluster:DescribeGroup"
        ]
        Resource = "arn:aws:kafka:*:*:group/${aws_msk_cluster.main[0].cluster_name}/*/*"
      }
    ]
  })
}
EOF

cat > "$TF_BACKEND/modules/msk/variables.tf" << 'EOF'
variable "project_name" {
  description = "Prefijo del proyecto"
  type        = string
}

variable "environment" {
  description = "Nombre del ambiente (dev/staging/prod)"
  type        = string
}

variable "vpc_id" {
  description = "ID de la VPC"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR de la VPC (acceso a los puertos Kafka/ZooKeeper)"
  type        = string
}

variable "subnet_ids" {
  description = "Subnets privadas; se necesita una por broker node (AZs distintas)"
  type        = list(string)
}

variable "kafka_version" {
  description = "Versión de Apache Kafka"
  type        = string
  default     = "3.7.x"
}

variable "number_of_broker_nodes" {
  description = "Número de brokers del cluster (debe ser múltiplo del número de AZs)"
  type        = number
  default     = 2
}

variable "broker_instance_type" {
  description = "Tipo de instancia MSK para los brokers"
  type        = string
  default     = "kafka.t3.small"
}

variable "broker_ebs_volume_size" {
  description = "Tamaño del volumen EBS por broker en GB"
  type        = number
  default     = 20
}

variable "enabled" {
  description = "Crear recursos MSK"
  type        = bool
  default     = true
}

variable "floci" {
  description = "Modo floci: cluster mínimo (sin configuration_info, logging_info ni open_monitoring)"
  type        = bool
  default     = false
}
EOF

cat > "$TF_BACKEND/modules/msk/outputs.tf" << 'EOF'
output "cluster_arn" {
  description = "ARN del cluster MSK"
  value       = try(aws_msk_cluster.main[0].arn, "")
}

output "cluster_name" {
  description = "Nombre del cluster MSK"
  value       = try(aws_msk_cluster.main[0].cluster_name, "")
}

output "bootstrap_brokers" {
  description = "Lista de brokers Kafka en texto plano (para conexiones internas en dev)"
  value       = try(aws_msk_cluster.main[0].bootstrap_brokers, "")
}

output "bootstrap_brokers_tls" {
  description = "Lista de brokers Kafka con TLS"
  value       = try(aws_msk_cluster.main[0].bootstrap_brokers_tls, "")
}

output "zookeeper_connect_string" {
  description = "String de conexión a ZooKeeper"
  value       = try(aws_msk_cluster.main[0].zookeeper_connect_string, "")
}

output "security_group_id" {
  description = "ID del SG del cluster MSK (añadir a los microservicios que lo consuman)"
  value       = try(aws_security_group.msk[0].id, "")
}

output "msk_access_policy_arn" {
  description = "ARN de la política IAM para producir/consumir en MSK (adjuntar al task role)"
  value       = try(aws_iam_policy.msk_access[0].arn, "")
}

output "cloudwatch_log_group" {
  description = "Nombre del log group de CloudWatch para los brokers MSK"
  value       = try(aws_cloudwatch_log_group.msk_broker[0].name, "")
}
EOF

log_ok "Módulo MSK listo."

# ===========================================================================
# BACKEND — módulo ArgoCD (CD por GitOps sobre EKS)
# ===========================================================================
#
# Instala ArgoCD en el cluster EKS vía Helm (provider helm). El CD es GitOps:
# ArgoCD observa helm/<service>/values-<env>.yaml en los repos de los servicios
# y sincroniza el cluster. Jenkins solo escribe el image tag (bumpImageTag).
#
# Los AppProject/ApplicationSet y las credenciales de repo se entregan como
# manifiestos en environments/<env>/argocd-bootstrap/ (se aplican con kubectl
# una vez que el cluster + ArgoCD están arriba), igual que el bootstrap RBAC de
# Jenkins. Solo aplica a staging/prod (clusters EKS reales); dev usa Floci.

log "Escribiendo módulo ArgoCD..."

cat > "$TF_BACKEND/modules/argocd/main.tf" << 'EOF'
# Instalación de ArgoCD con el chart oficial argo-helm.
# Los providers helm/kubernetes se configuran en el entorno (apuntando al EKS).
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  namespace        = var.namespace
  create_namespace = true

  # TLS terminado en el LoadBalancer; el server corre en modo insecure detrás de él.
  values = [yamlencode({
    global = {
      domain = var.argocd_domain
    }
    configs = {
      params = {
        "server.insecure" = true
      }
    }
    server = {
      service = {
        type = var.server_service_type
      }
    }
    # En prod conviene HA; en otros ambientes, instalación mínima.
    controller = {
      replicas = var.environment == "prod" ? 1 : 1
    }
    redis-ha = {
      enabled = var.environment == "prod"
    }
    repoServer = {
      replicas = var.environment == "prod" ? 2 : 1
    }
  })]
}
EOF

cat > "$TF_BACKEND/modules/argocd/variables.tf" << 'EOF'
variable "project_name" {
  description = "Prefijo del proyecto"
  type        = string
}

variable "environment" {
  description = "Nombre del ambiente (staging/prod)"
  type        = string
}

variable "namespace" {
  description = "Namespace donde se instala ArgoCD"
  type        = string
  default     = "argocd"
}

variable "argocd_chart_version" {
  description = "Versión del chart argo-cd (argo-helm)"
  type        = string
  default     = "7.6.12"
}

variable "argocd_domain" {
  description = "Dominio público de la UI de ArgoCD (informativo si se usa LoadBalancer)"
  type        = string
  default     = "argocd.example.com"
}

variable "server_service_type" {
  description = "Tipo de Service del argocd-server (LoadBalancer expone una URL)"
  type        = string
  default     = "LoadBalancer"
}
EOF

cat > "$TF_BACKEND/modules/argocd/outputs.tf" << 'EOF'
output "namespace" {
  description = "Namespace donde quedó instalado ArgoCD"
  value       = helm_release.argocd.namespace
}

output "release_name" {
  description = "Nombre del Helm release de ArgoCD"
  value       = helm_release.argocd.name
}

output "admin_password_cmd" {
  description = "Comando para leer la contraseña inicial del admin de ArgoCD"
  value       = "kubectl -n ${helm_release.argocd.namespace} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}

output "server_url_cmd" {
  description = "Comando para obtener la URL (hostname del LoadBalancer) del argocd-server"
  value       = "kubectl -n ${helm_release.argocd.namespace} get svc argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
}
EOF

log_ok "Módulo ArgoCD listo."

# ===========================================================================
# BACKEND — entorno dev (Floci)
# ===========================================================================

cat > "$TF_BACKEND/environments/dev/providers.tf" << 'EOF'
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

# Providers Kubernetes/Helm apuntando al cluster K3d local (lo crea floci-start con
# `k3d cluster create __PROJECT_NAME__-dev`). A diferencia de staging/prod (EKS, auth por
# `aws eks get-token`), aquí la autenticación es por certificado de cliente del
# kubeconfig que k3d genera. El cluster debe existir antes de `terraform apply`.
provider "kubernetes" {
  config_path    = "${path.module}/.kube/config-k3d"
  config_context = "k3d-__PROJECT_NAME__-dev"
}

provider "helm" {
  kubernetes {
    config_path    = "${path.module}/.kube/config-k3d"
    config_context = "k3d-__PROJECT_NAME__-dev"
  }
}

# Floci — emulador AWS local (puerto 4566)
provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    ec2              = "http://localhost:4566"
    eks              = "http://localhost:4566"
    rds              = "http://localhost:4566"
    s3               = "http://localhost:4566"
    iam              = "http://localhost:4566"
    sts              = "http://localhost:4566"
    cognitoidp       = "http://localhost:4566"
    apigateway       = "http://localhost:4566"
    apigatewayv2     = "http://localhost:4566"
    secretsmanager         = "http://localhost:4566"
    ecr                    = "http://localhost:4566"
    elasticloadbalancing   = "http://localhost:4566"
    elasticloadbalancingv2 = "http://localhost:4566"
    kafka                  = "http://localhost:4566"
    cloudwatchlogs       = "http://localhost:4566"
    ssm                  = "http://localhost:4566"
    autoscaling          = "http://localhost:4566"
    lambda               = "http://localhost:4566"
    events               = "http://localhost:4566"
  }
}

provider "archive" {}
EOF

cat > "$TF_BACKEND/environments/dev/variables.tf" << 'EOF'
variable "aws_region" {
  description = "Región AWS"
  type        = string
  default     = "us-east-1"
}

variable "vpc_id" {
  description = "ID de la VPC (floci: valor de prueba)"
  type        = string
  default     = "vpc-00000000"
}

variable "vpc_cidr" {
  description = "CIDR de la VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_ids" {
  description = "Subnets privadas (floci: valores de prueba)"
  type        = list(string)
  default     = ["subnet-00000001", "subnet-00000002"]
}

variable "public_subnet_ids" {
  description = "Subnets públicas para el ALB (floci: mismas que privadas)"
  type        = list(string)
  default     = ["subnet-00000001", "subnet-00000002"]
}

variable "ami_id" {
  description = "AMI base del controller Jenkins (floci: valor de prueba)"
  type        = string
  default     = "ami-00000000"
}

variable "availability_zone" {
  description = "Availability Zone (floci: valor de prueba)"
  type        = string
  default     = "us-east-1a"
}

variable "db_name" {
  description = "Nombre de la base de datos inicial (floci: valor de prueba)"
  type        = string
  default     = "__PROJECT_NAME___dev"
}

variable "db_username" {
  description = "Usuario administrador de la base de datos (floci: valor de prueba)"
  type        = string
  default     = "admin"
}

variable "db_password" {
  description = "Contraseña del usuario administrador (floci: valor de prueba)"
  type        = string
  default     = "changeme123"
  sensitive   = true
}

variable "vpc_security_group_ids" {
  description = "IDs de security groups con acceso a RDS (floci: valor de prueba)"
  type        = list(string)
  default     = ["sg-00000000"]
}

variable "shared_library_repo" {
  description = "URL git del repositorio jenkins-shared-library"
  type        = string
  default     = ""
}

variable "sonar_url" {
  description = "URL del servidor SonarQube"
  type        = string
  default     = ""
}

variable "sonar_token" {
  description = "Token de autenticación de SonarQube"
  type        = string
  sensitive   = true
  default     = ""
}

variable "slack_team" {
  description = "Workspace de Slack"
  type        = string
  default     = ""
}

variable "slack_token" {
  description = "Token del bot de Slack"
  type        = string
  sensitive   = true
  default     = ""
}

variable "vercel_token" {
  description = "Token de servicio de Vercel"
  type        = string
  sensitive   = true
  default     = ""
}

variable "vercel_org_id" {
  description = "ID de la organización en Vercel"
  type        = string
  default     = ""
}

variable "vercel_project_id" {
  description = "ID del proyecto en Vercel"
  type        = string
  default     = ""
}

variable "gitops_git_username" {
  description = "Usuario git para bumpImageTag"
  type        = string
  default     = ""
}

variable "gitops_git_token" {
  description = "Token git para bumpImageTag"
  type        = string
  sensitive   = true
  default     = ""
}
EOF

cat > "$TF_BACKEND/environments/dev/main.tf" << 'EOF'
# Floci tiene una VPC por defecto; la descubrimos en lugar de usar IDs hardcodeados.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

locals {
  project_name = "__PROJECT_NAME__"
  environment  = "dev"
  services     = []

  vpc_id     = data.aws_vpc.default.id
  vpc_cidr   = data.aws_vpc.default.cidr_block
  subnet_ids = data.aws_subnets.default.ids

  # Apache Kafka nativo (KRaft) en el VPS. Acceso desde microservicios (K3s pods): VPS_IP:9092.
  # Externo (CLI/herramientas desde el host): VPS_IP:29092.
  kafka_bootstrap_brokers          = "__VPS_IP__:9092"
  kafka_bootstrap_brokers_external = "__VPS_IP__:29092"

  # Registry de imágenes de dev: Gitea Package Registry (OCI nativo) en el VPS.
  # Jenkins push: docker push __VPS_IP__:3000/__PROJECT_NAME__/<servicio>:<tag>
  # K3s pull: usa imagePullSecrets con credenciales de Gitea.
  gitea_registry = "__VPS_IP__:3000/__PROJECT_NAME__"
}

module "iam" {
  source       = "../../modules/iam"
  environment  = local.environment
  project_name = local.project_name
}

module "cognito" {
  source        = "../../modules/cognito"
  environment   = local.environment
  project_name  = local.project_name
  enable_domain = false
  emulator      = true
}

module "api_gateway" {
  source                     = "../../modules/api-gateway"
  environment                = local.environment
  project_name               = local.project_name
  cognito_user_pool_endpoint = module.cognito.user_pool_endpoint
  cognito_client_id          = module.cognito.client_id

  depends_on = [module.cognito]
}

module "secrets_manager" {
  source      = "../../modules/secrets-manager"
  environment = local.environment
  services    = local.services
}

# ECR eliminado en dev: Gitea Package Registry (OCI nativo) reemplaza ECR.
# El módulo terraform/backend/modules/ecr se conserva para staging/prod (AWS ECR real).

# RDS eliminado en dev: PostgreSQL 16 corre como servicio nativo (postgresql.service)
# en el VPS. Conexión directa: __VPS_IP__:5432. Sin Terraform ni floci.
# El módulo terraform/backend/modules/rds se conserva para staging/prod (AWS RDS real).

# MSK eliminado en dev: Kafka nativo (KRaft) en el VPS (__VPS_IP__:9092).
# El módulo terraform/backend/modules/msk se conserva para staging/prod (AWS MSK real).

# ArgoCD se instala en K3s nativo del VPS via Helm CLI (vps-setup.sh k3s).
# Los ApplicationSet/AppProject se aplican desde environments/dev/argocd-bootstrap/.
# El módulo terraform/backend/modules/argocd se conserva para staging/prod (EKS real).
EOF

# Sustituir placeholders
sed -i \
  -e "s/__PROJECT_NAME__/${PROJECT_NAME}/g" \
  -e "s/__VPS_IP__/${VPS_IP}/g" \
  "$TF_BACKEND/environments/dev/main.tf"

# Capa serverless de reportería (EventBridge + lambdas PDF/XLS/CSV).
# Se activa cuando ENABLE_REPORTING_SERVERLESS=1 (default). El módulo se popula con
# report_lambdas_scaffold.py; debe ejecutarse antes del primer `terraform apply`.
if [[ "$ENABLE_REPORTING_SERVERLESS" == "1" ]]; then
  cat >> "$TF_BACKEND/environments/dev/main.tf" << 'EOFMOD'

# Activa este módulo después de ejecutar report_lambdas_scaffold.py.
# module "reporting_lambdas" {
#   source                  = "../../modules/reporting-lambdas"
#   org                     = local.project_name
#   kafka_topic             = "report.processed"
#   kafka_bootstrap_servers = local.kafka_bootstrap_brokers
#   lambda_runtime          = "python3.12"
#   report_bucket           = "${local.project_name}-reports"
#   aws_endpoint_url        = "http://localhost:4566"
# }
EOFMOD
  log_ok "Bloque module reporting_lambdas añadido a environments/dev/main.tf (comentado hasta ejecutar scaffold)."
fi

cat > "$TF_BACKEND/environments/dev/outputs.tf" << 'EOF'
output "api_endpoint" {
  description = "URL base del API Gateway (floci)"
  value       = module.api_gateway.api_endpoint
}

output "user_pool_id" {
  description = "ID del User Pool de Cognito (floci)"
  value       = module.cognito.user_pool_id
}

output "user_pool_client_id" {
  description = "App Client ID de Cognito (floci)"
  value       = module.cognito.client_id
}

output "user_pool_endpoint" {
  description = "Endpoint del User Pool de Cognito (issuer JWT para NextAuth y API Gateway)"
  value       = module.cognito.user_pool_endpoint
}

# Registry de imágenes: Gitea Package Registry (OCI nativo) en el VPS.
# setup-cicd-pipeline.sh lee este output para configurar GITEA_REGISTRY en Jenkins.
output "gitea_registry" {
  description = "Registry de imágenes de dev (Gitea Package Registry en VPS). Formato: <VPS_IP>:3000/<org>"
  value       = local.gitea_registry
}

output "secret_arns" {
  description = "ARNs de los secrets en Secrets Manager (floci)"
  value       = module.secrets_manager.secret_arns
  sensitive   = true
}

output "task_execution_role_arn" {
  description = "ARN del ECS task execution role"
  value       = module.iam.task_execution_role_arn
}

output "task_role_arn" {
  description = "ARN del ECS task role"
  value       = module.iam.task_role_arn
}

# ArgoCD se instaló via Helm en K3s nativo (vps-setup.sh k3s).
# UI: http://<VPS_IP>:30080  |  HTTPS: http://<VPS_IP>:30443
# Password admin: kubectl --kubeconfig ~/.kube/config-k3s-vps \
#   get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d
output "argocd_ui_url" {
  description = "URL de la UI de ArgoCD en K3s (NodePort)"
  value       = "http://__VPS_IP__:30080"
}

output "kafka_bootstrap_brokers" {
  description = "Bootstrap brokers de Kafka nativo en VPS (para microservicios en K3s)"
  value       = local.kafka_bootstrap_brokers
}

output "kafka_bootstrap_brokers_external" {
  description = "Bootstrap brokers de Kafka accesibles desde el host"
  value       = local.kafka_bootstrap_brokers_external
}

# PostgreSQL nativo en VPS: acceder directamente via VPS_IP:5432
# Sin módulo Terraform — las BDs se crean con init-databases.sh apuntando al VPS.
output "postgres_host" {
  description = "Host de PostgreSQL nativo en VPS (no gestionado por Terraform)"
  value       = "__VPS_IP__"
}

output "postgres_port" {
  description = "Puerto de PostgreSQL nativo en VPS"
  value       = 5432
}
EOF

sed -i "s/__VPS_IP__/${VPS_IP}/g" "$TF_BACKEND/environments/dev/outputs.tf"

# --- Manifiestos bootstrap de ArgoCD para dev (K3d) --------------------------
# Mismos objetos que staging/prod (AppProject + ApplicationSet + repo-creds), pero
# con auto-sync y apuntando a Gitea en floci-net. Se generan aquí (no en el loop
# staging/prod) para no pisar los archivos de entorno de dev escritos arriba.
# Se aplican con setup-cicd-pipeline.sh (Sección 5) una vez ArgoCD está arriba.

cat > "$TF_BACKEND/environments/dev/argocd-bootstrap/appproject.yaml" << 'EOF'
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: __PROJECT_NAME__
  namespace: argocd
spec:
  description: Microservicios __PROJECT_NAME__ (dev)
  sourceRepos:
    - '*'
  destinations:
    - server: https://kubernetes.default.svc
      namespace: '*'
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
  namespaceResourceWhitelist:
    - group: '*'
      kind: '*'
EOF

# ApplicationSet: una Application por servicio. ArgoCD lee helm/<service>/values-dev.yaml
# del repo del servicio en Gitea. Las entradas se añaden al correr maven_hexagonal_scaffold.py.
cat > "$TF_BACKEND/environments/dev/argocd-bootstrap/applicationset.yaml" << 'EOF'
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: __PROJECT_NAME__-dev
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - list:
        elements:
          # -- services managed by scaffold --
          # repoURL apunta a Gitea en floci-net (http://gitea:3000); ArgoCD (pod en
          # el cluster K3d __PROJECT_NAME__-dev) lo alcanza porque está en la misma red floci-net.
  template:
    metadata:
      name: '{{.service}}-dev'
    spec:
      project: __PROJECT_NAME__
      source:
        repoURL: '{{.repoURL}}'
        targetRevision: '{{.revision}}'
        path: 'helm/{{.service}}'
        helm:
          valueFiles:
            - 'values-dev.yaml'
      destination:
        server: https://kubernetes.default.svc
        namespace: dev
      # dev: auto-sync con prune + selfHeal (corrige drift automáticamente).
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
EOF

cat > "$TF_BACKEND/environments/dev/argocd-bootstrap/repo-credentials.example.yaml" << 'EOF'
# Credenciales de repositorio para ArgoCD. ArgoCD (pod en el cluster K3d
# __PROJECT_NAME__-dev) alcanza Gitea por http://gitea:3000 porque ambos están en floci-net.
# Aplicar con: kubectl apply -f repo-credentials.example.yaml
apiVersion: v1
kind: Secret
metadata:
  name: repo-creds-gitea-__PROJECT_NAME__
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repo-creds
stringData:
  type: git
  url: http://gitea:3000/__PROJECT_NAME__
  username: gitea-admin
  password: gitea-admin
EOF

# RBAC del agente Jenkins en K3d (sin IRSA: K3d no es AWS). El controller Jenkins
# (contenedor en floci-net) lanza agentes como pods en el namespace 'jenkins'. Para
# los smoke tests post-sync, el SA jenkins-agent necesita leer el deployment y crear
# el pod de prueba en el namespace de la app (dev). Reemplaza al bootstrap con IRSA
# de staging/prod. Lo aplica setup-cicd-pipeline.sh (Sección 2) en dev.
cat > "$TF_BACKEND/environments/dev/argocd-bootstrap/jenkins-agent-rbac-dev.yaml" << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: jenkins
---
apiVersion: v1
kind: Namespace
metadata:
  name: dev
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: jenkins-agent
  namespace: jenkins
---
# Smoke tests: el agente consulta el rollout y lanza un pod curl en el namespace dev.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: jenkins-agent-smoke
  namespace: dev
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list", "watch", "create", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: jenkins-agent-smoke
  namespace: dev
subjects:
  - kind: ServiceAccount
    name: jenkins-agent
    namespace: jenkins
roleRef:
  kind: Role
  name: jenkins-agent-smoke
  apiGroup: rbac.authorization.k8s.io
EOF

# ===========================================================================
# BACKEND — entornos staging y prod (AWS real)
# ===========================================================================

for env in staging prod; do
cat > "$TF_BACKEND/environments/$env/providers.tf" << 'EOF'
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

provider "archive" {}

# Providers Kubernetes/Helm apuntando al cluster EKS de este ambiente (lo crea
# module.eks). Autenticación vía exec (aws eks get-token).
#
# NOTA (orden de bootstrap): host/CA provienen de outputs de un recurso creado
# en este mismo apply. En el PRIMER apply de un ambiente nuevo, crea primero el
# cluster y luego el resto:
#   terraform apply -target=module.eks
#   terraform apply
# Los applies posteriores ya no necesitan -target.
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
    }
  }
}
EOF

cat > "$TF_BACKEND/environments/$env/variables.tf" << 'EOF'
variable "aws_region" {
  description = "Región AWS"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefijo del proyecto"
  type        = string
}

variable "services" {
  description = "Lista de microservicios del proyecto"
  type        = list(string)
}

variable "vpc_id" {
  description = "ID de la VPC donde se despliega la infraestructura"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR de la VPC"
  type        = string
}

variable "subnet_ids" {
  description = "Subnets privadas (ECS tasks, RDS)"
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Subnets públicas para el ALB de Jenkins"
  type        = list(string)
}

variable "ami_id" {
  description = "AMI base (Amazon Linux 2023) para la instancia EC2 del controller Jenkins"
  type        = string
}

variable "db_name" {
  description = "Nombre de la base de datos inicial"
  type        = string
}

variable "db_username" {
  description = "Usuario administrador de la base de datos"
  type        = string
}

variable "db_password" {
  description = "Contraseña del usuario administrador"
  type        = string
  sensitive   = true
}

variable "vpc_security_group_ids" {
  description = "IDs de security groups con acceso a RDS"
  type        = list(string)
}

variable "shared_library_repo" {
  description = "URL git del repositorio jenkins-shared-library"
  type        = string
}

variable "sonar_url" {
  description = "URL del servidor SonarQube"
  type        = string
}

variable "sonar_token" {
  description = "Token de autenticación de SonarQube"
  type        = string
  sensitive   = true
}

variable "slack_team" {
  description = "Workspace de Slack"
  type        = string
}

variable "slack_token" {
  description = "Token del bot de Slack"
  type        = string
  sensitive   = true
}

variable "vercel_token" {
  description = "Token de servicio de Vercel"
  type        = string
  sensitive   = true
}

variable "vercel_org_id" {
  description = "ID de la organización en Vercel"
  type        = string
}

variable "vercel_project_id" {
  description = "ID del proyecto en Vercel"
  type        = string
}

variable "gitops_git_username" {
  description = "Usuario git para bumpImageTag"
  type        = string
}

variable "gitops_git_token" {
  description = "Token git para bumpImageTag"
  type        = string
  sensitive   = true
}
EOF

cat > "$TF_BACKEND/environments/$env/main.tf" << EOF
locals {
  environment = "$env"
}

module "iam" {
  source       = "../../modules/iam"
  environment  = local.environment
  project_name = var.project_name
}

module "cognito" {
  source       = "../../modules/cognito"
  environment  = local.environment
  project_name = var.project_name
}

module "api_gateway" {
  source                     = "../../modules/api-gateway"
  environment                = local.environment
  project_name               = var.project_name
  cognito_user_pool_endpoint = module.cognito.user_pool_endpoint
  cognito_client_id          = module.cognito.client_id

  depends_on = [module.cognito]
}

module "secrets_manager" {
  source      = "../../modules/secrets-manager"
  environment = local.environment
  services    = var.services
}

module "ecr" {
  source       = "../../modules/ecr"
  environment  = local.environment
  project_name = var.project_name
  services     = var.services
}

module "eks" {
  source       = "../../modules/eks"
  environment  = local.environment
  project_name = var.project_name
  subnet_ids   = var.subnet_ids
}

module "jenkins" {
  source                = "../../modules/jenkins"
  environment           = local.environment
  project_name          = var.project_name
  vpc_id                = var.vpc_id
  vpc_cidr              = var.vpc_cidr
  subnet_ids            = var.subnet_ids
  public_subnet_ids     = var.public_subnet_ids
  ami_id                = var.ami_id
  aws_region            = var.aws_region
  alb_internal          = true
  eks_cluster_name      = module.eks.cluster_name
  eks_cluster_endpoint  = module.eks.cluster_endpoint
  eks_oidc_provider_arn = module.eks.oidc_provider_arn
  eks_oidc_issuer_host  = module.eks.oidc_issuer_host
  shared_library_repo   = var.shared_library_repo
  sonar_url             = var.sonar_url
  sonar_token           = var.sonar_token
  slack_team            = var.slack_team
  slack_token           = var.slack_token
  vercel_token          = var.vercel_token
  vercel_org_id         = var.vercel_org_id
  vercel_project_id     = var.vercel_project_id
  gitops_git_username   = var.gitops_git_username
  gitops_git_token      = var.gitops_git_token
}

module "msk" {
  source       = "../../modules/msk"
  environment  = local.environment
  project_name = var.project_name
  vpc_id       = var.vpc_id
  vpc_cidr     = var.vpc_cidr
  subnet_ids   = var.subnet_ids
}

module "rds" {
  source                  = "../../modules/rds"
  environment             = local.environment
  project_name            = var.project_name
  subnet_ids              = var.subnet_ids
  vpc_security_group_ids  = var.vpc_security_group_ids
  db_name                 = var.db_name
  db_username             = var.db_username
  db_password             = var.db_password
}

# ArgoCD (CD por GitOps). Se instala en el cluster EKS de este ambiente; los
# ApplicationSet/AppProject se aplican desde environments/$env/argocd-bootstrap/.
module "argocd" {
  source       = "../../modules/argocd"
  environment  = local.environment
  project_name = var.project_name

  depends_on = [module.eks]
}

# Activa este módulo después de ejecutar report_lambdas_scaffold.py.
# module "reporting_lambdas" {
#   source           = "../../modules/reporting-lambdas"
#   org              = var.project_name
#   kafka_topic      = "report.processed"
#   lambda_runtime   = "python3.12"
#   report_bucket    = "\${var.project_name}-reports"
#   aws_endpoint_url = ""
# }
EOF

cat > "$TF_BACKEND/environments/$env/outputs.tf" << 'EOF'
output "api_endpoint" {
  description = "URL base del API Gateway"
  value       = module.api_gateway.api_endpoint
}

output "user_pool_id" {
  description = "ID del User Pool de Cognito"
  value       = module.cognito.user_pool_id
}

output "user_pool_client_id" {
  description = "App Client ID de Cognito"
  value       = module.cognito.client_id
}

output "user_pool_endpoint" {
  description = "Endpoint del User Pool de Cognito (issuer JWT para NextAuth y API Gateway)"
  value       = module.cognito.user_pool_endpoint
}

output "ecr_repository_urls" {
  description = "URLs de los repositorios ECR"
  value       = module.ecr.repository_urls
}

output "ecr_registry" {
  description = "URL base del registry ECR (para docker login y construcción de image tags)"
  value       = try(split("/", values(module.ecr.repository_urls)[0])[0], null)
}

output "secret_arns" {
  description = "ARNs de los secrets en Secrets Manager"
  value       = module.secrets_manager.secret_arns
  sensitive   = true
}

output "task_execution_role_arn" {
  description = "ARN del ECS task execution role"
  value       = module.iam.task_execution_role_arn
}

output "task_role_arn" {
  description = "ARN del ECS task role"
  value       = module.iam.task_role_arn
}

output "jenkins_url" {
  description = "URL de acceso a la UI de Jenkins"
  value       = module.jenkins.jenkins_url
}

output "jenkins_ebs_volume_id" {
  description = "ID del volumen EBS que persiste JENKINS_HOME"
  value       = module.jenkins.ebs_volume_id
}

output "jenkins_agent_role_arn" {
  description = "ARN del IAM role del agente Jenkins (IRSA para pods en EKS)"
  value       = module.jenkins.agent_role_arn
}

output "msk_cluster_arn" {
  description = "ARN del cluster MSK"
  value       = module.msk.cluster_arn
}

output "msk_bootstrap_brokers" {
  description = "Bootstrap brokers Kafka (plaintext)"
  value       = module.msk.bootstrap_brokers
}

output "msk_bootstrap_brokers_tls" {
  description = "Bootstrap brokers Kafka (TLS)"
  value       = module.msk.bootstrap_brokers_tls
}

output "msk_access_policy_arn" {
  description = "ARN de la política IAM para adjuntar al task role de los microservicios"
  value       = module.msk.msk_access_policy_arn
}

output "argocd_namespace" {
  description = "Namespace donde quedó instalado ArgoCD"
  value       = module.argocd.namespace
}

output "argocd_admin_password_cmd" {
  description = "Comando para leer la contraseña inicial del admin de ArgoCD"
  value       = module.argocd.admin_password_cmd
}

output "argocd_server_url_cmd" {
  description = "Comando para obtener la URL (LoadBalancer) del argocd-server"
  value       = module.argocd.server_url_cmd
}

output "rds_endpoint" {
  description = "Endpoint de conexión a RDS"
  value       = module.rds.endpoint
}

output "rds_port" {
  description = "Puerto de conexión a RDS"
  value       = module.rds.port
}

output "rds_db_name" {
  description = "Nombre de la base de datos"
  value       = module.rds.db_name
}

output "rds_arn" {
  description = "ARN de la instancia RDS"
  value       = module.rds.arn
}
EOF

# --- Manifiestos bootstrap de ArgoCD por ambiente ----------------------------
# AppProject + ApplicationSet + credenciales de repo. Se aplican una vez que el
# cluster + ArgoCD están arriba:  kubectl apply -f environments/$env/argocd-bootstrap/
# El syncPolicy depende del ambiente: staging = automated; prod = manual.

if [ "$env" = "prod" ]; then
  SYNC_POLICY_BLOCK="      # prod: SIN automated → sync MANUAL desde la UI de ArgoCD (gate de release).
      syncPolicy:
        syncOptions:
          - CreateNamespace=true"
else
  SYNC_POLICY_BLOCK="      # $env: auto-sync con prune + selfHeal (corrige drift automáticamente).
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true"
fi

cat > "$TF_BACKEND/environments/$env/argocd-bootstrap/appproject.yaml" << EOF
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: ${PROJECT_NAME}
  namespace: argocd
spec:
  description: Microservicios ${PROJECT_NAME} ($env)
  sourceRepos:
    - '*'              # restringe a los repos de tus servicios en producción
  destinations:
    - server: https://kubernetes.default.svc
      namespace: '*'
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
  namespaceResourceWhitelist:
    - group: '*'
      kind: '*'
EOF

# ApplicationSet: una Application por servicio. Cada servicio vive en su propio
# repo (misma fuente que el código), y ArgoCD lee helm/<service>/values-$env.yaml.
# AÑADE un elemento por servicio (name + repoURL del repo del servicio).
cat > "$TF_BACKEND/environments/$env/argocd-bootstrap/applicationset.yaml" << EOF
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: ${PROJECT_NAME}-$env
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - list:
        elements:
          # -- services managed by scaffold --
          # Las entradas se añaden automáticamente al correr maven_hexagonal_scaffold.py.
          # repoURL apunta a Gitea en floci-net (http://gitea:3000); ArgoCD llega a él
          # porque el cluster K3d (donde corre k3s) está en la misma red floci-net.
  template:
    metadata:
      name: '{{.service}}-$env'
    spec:
      project: ${PROJECT_NAME}
      source:
        repoURL: '{{.repoURL}}'
        targetRevision: '{{.revision}}'
        path: 'helm/{{.service}}'
        helm:
          valueFiles:
            - 'values-$env.yaml'
      destination:
        server: https://kubernetes.default.svc
        namespace: $env
$SYNC_POLICY_BLOCK
EOF

cat > "$TF_BACKEND/environments/$env/argocd-bootstrap/repo-credentials.example.yaml" << 'EOF'
# Credenciales de repositorio para ArgoCD (un Secret por organización en Gitea).
# ArgoCD usa estas credenciales para clonar los repos al sincronizar.
# Aplicar con: kubectl apply -f repo-credentials.example.yaml
#
# En dev (floci): Gitea corre en floci-net como contenedor "gitea".
# ArgoCD (pod en k3s dentro de el cluster K3d) alcanza Gitea via http://gitea:3000
# porque el cluster K3d está en la misma red floci-net.
apiVersion: v1
kind: Secret
metadata:
  name: repo-creds-gitea-__PROJECT_NAME__
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repo-creds
stringData:
  type: git
  url: http://gitea:3000/__PROJECT_NAME__
  username: gitea-admin
  password: gitea-admin
EOF

done

# ---------------------------------------------------------------------------
# Sustituye el placeholder __PROJECT_NAME__ en los archivos Terraform/YAML
# generados por el nombre real del proyecto.
# ---------------------------------------------------------------------------
log "Aplicando nombre de proyecto '$PROJECT_NAME' al árbol Terraform generado..."
find "$TERRAFORM_ROOT" -type f \
  \( -name '*.tf' -o -name '*.yaml' -o -name '*.yml' -o -name '*.tfvars' -o -name '*.json' \) \
  -print0 | xargs -0 --no-run-if-empty sed -i \
    -e "s#__PROJECT_NAME__#${PROJECT_NAME}#g"
log_ok "Nombre de proyecto '$PROJECT_NAME' aplicado al árbol Terraform."

log_ok "Estructura Terraform creada en $TERRAFORM_ROOT."
