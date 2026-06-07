#!/usr/bin/env bash

set -euo pipefail

log()     { echo "[$(date '+%H:%M:%S')] $*"; }
log_ok()  { echo "[$(date '+%H:%M:%S')] OK  $*"; }
log_err() { echo "[$(date '+%H:%M:%S')] ERR $*" >&2; }

BOLD="\033[1m"
RESET="\033[0m"
HEADER() { echo -e "\n${BOLD}━━━ $* ━━━${RESET}"; }

# ---------------------------------------------------------------------------
# Argumentos
# ---------------------------------------------------------------------------
PROJECT_NAME=""
usage() {
  cat <<USAGE
Uso: $0 -P <proyecto>

  -P, --project NOMBRE   Slug del proyecto (mismo que el resto de scripts).
                         Nombra el OTEL Collector (<proyecto>-otel-collector)
                         y las claves en .observability-env. (obligatorio)
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
KUBECONFIG_PATH="$REPO_ROOT/terraform/backend/environments/dev/.kube/config-k3d"
OBS_ENV_FILE="$REPO_ROOT/terraform/backend/environments/dev/.observability-env"

export KUBECONFIG="$KUBECONFIG_PATH"

log "Configurando observabilidad para el proyecto: $PROJECT_NAME"

# ---------------------------------------------------------------------------
# Dependencias
# ---------------------------------------------------------------------------
HEADER "Verificando dependencias"
for cmd in helm kubectl; do
  if command -v "$cmd" &>/dev/null; then
    log_ok "$cmd encontrado."
  else
    log_err "$cmd no está instalado. Abortando."
    exit 1
  fi
done

kubectl cluster-info --request-timeout=5s &>/dev/null \
  || { log_err "No hay conectividad con el cluster K3d. Ejecuta init-dev-environment.sh primero."; exit 1; }
log_ok "Cluster K3d accesible."

# ---------------------------------------------------------------------------
# Paso 1 — Repositorios Helm
# ---------------------------------------------------------------------------
HEADER "Paso 1 — Repositorios Helm"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add grafana             https://grafana.github.io/helm-charts              2>/dev/null || true
helm repo add jaegertracing       https://jaegertracing.github.io/helm-charts        2>/dev/null || true
helm repo add fluent              https://fluent.github.io/helm-charts               2>/dev/null || true
helm repo update
log_ok "Repositorios Helm actualizados."

# ---------------------------------------------------------------------------
# Paso 2 — kube-prometheus-stack (Prometheus + Grafana + Alertmanager)
# ---------------------------------------------------------------------------
HEADER "Paso 2 — kube-prometheus-stack"
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set grafana.adminPassword=admin \
  --set grafana.fullnameOverride="${PROJECT_NAME}-grafana" \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --wait --timeout=5m
log_ok "kube-prometheus-stack instalado."

# ---------------------------------------------------------------------------
# Paso 3 — Jaeger all-in-one
# ---------------------------------------------------------------------------
HEADER "Paso 3 — Jaeger all-in-one"
kubectl create namespace tracing --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install jaeger jaegertracing/jaeger \
  --namespace tracing \
  --set allInOne.enabled=true \
  --set storage.type=memory \
  --set agent.enabled=false \
  --set collector.enabled=false \
  --set query.enabled=false \
  --wait --timeout=3m
log_ok "Jaeger all-in-one instalado."

# ---------------------------------------------------------------------------
# Paso 4 — OTEL Collector (Deployment + ConfigMap)
# ---------------------------------------------------------------------------
HEADER "Paso 4 — OTEL Collector"

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${PROJECT_NAME}-otel-collector
  namespace: monitoring
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318

    processors:
      batch:
        timeout: 5s

    exporters:
      # Dev: envía trazas a Jaeger all-in-one
      otlp/jaeger:
        endpoint: jaeger.tracing:4317
        tls:
          insecure: true
      # Dev: logs/métricas a stdout (referencia)
      logging:
        verbosity: normal

    service:
      pipelines:
        traces:
          receivers:  [otlp]
          processors: [batch]
          exporters:  [otlp/jaeger]
        metrics:
          receivers:  [otlp]
          processors: [batch]
          exporters:  [logging]
        logs:
          receivers:  [otlp]
          processors: [batch]
          exporters:  [logging]
EOF

kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${PROJECT_NAME}-otel-collector
  namespace: monitoring
  labels:
    app: ${PROJECT_NAME}-otel-collector
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${PROJECT_NAME}-otel-collector
  template:
    metadata:
      labels:
        app: ${PROJECT_NAME}-otel-collector
    spec:
      containers:
        - name: otel-collector
          image: otel/opentelemetry-collector-contrib:0.96.0
          args: ["--config=/etc/otel/config.yaml"]
          ports:
            - containerPort: 4317  # gRPC OTLP
            - containerPort: 4318  # HTTP OTLP
          volumeMounts:
            - name: config
              mountPath: /etc/otel
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
      volumes:
        - name: config
          configMap:
            name: ${PROJECT_NAME}-otel-collector
---
apiVersion: v1
kind: Service
metadata:
  name: ${PROJECT_NAME}-otel-collector
  namespace: monitoring
spec:
  selector:
    app: ${PROJECT_NAME}-otel-collector
  ports:
    - name: grpc
      port: 4317
      targetPort: 4317
    - name: http
      port: 4318
      targetPort: 4318
EOF

log_ok "OTEL Collector desplegado."

# ---------------------------------------------------------------------------
# Paso 5 — Fluent Bit DaemonSet → Loki
# ---------------------------------------------------------------------------
HEADER "Paso 5 — Loki + Fluent Bit"

helm upgrade --install loki grafana/loki \
  --namespace monitoring \
  --set loki.auth_enabled=false \
  --set deploymentMode=SingleBinary \
  --set singleBinary.replicas=1 \
  --set loki.commonConfig.replication_factor=1 \
  --set loki.storage.type=filesystem \
  --set read.replicas=0 \
  --set write.replicas=0 \
  --set backend.replicas=0 \
  --wait --timeout=4m

helm upgrade --install fluent-bit fluent/fluent-bit \
  --namespace monitoring \
  --set config.outputs="[OUTPUT]
    Name        loki
    Match       kube.*
    Host        loki.monitoring
    Port        3100
    Labels      job=fluentbit,namespace=\$kubernetes['namespace_name'],pod=\$kubernetes['pod_name']
    label_keys  \$traceId,\$spanId
    auto_kubernetes_labels on" \
  --wait --timeout=3m

log_ok "Loki + Fluent Bit instalados."

# ---------------------------------------------------------------------------
# Paso 6 — Persistir endpoints en .observability-env
# ---------------------------------------------------------------------------
HEADER "Paso 6 — Guardando endpoints en .observability-env"

mkdir -p "$(dirname "$OBS_ENV_FILE")"
cat > "$OBS_ENV_FILE" <<ENVFILE
# Generado por setup-observability.sh — $(date '+%Y-%m-%d %H:%M:%S')
# Endpoints internos del cluster K3d (usar dentro del cluster):
OTEL_COLLECTOR_GRPC=${PROJECT_NAME}-otel-collector.monitoring:4317
OTEL_COLLECTOR_HTTP=${PROJECT_NAME}-otel-collector.monitoring:4318
PROMETHEUS_INTERNAL=prometheus-operated.monitoring:9090
GRAFANA_INTERNAL=${PROJECT_NAME}-grafana.monitoring:80
LOKI_INTERNAL=loki.monitoring:3100
JAEGER_INTERNAL=jaeger.tracing:16686

# Port-forwards para acceso local (ejecutar manualmente):
# kubectl --kubeconfig=$KUBECONFIG_PATH port-forward svc/prometheus-operated 9090:9090 -n monitoring
# kubectl --kubeconfig=$KUBECONFIG_PATH port-forward svc/${PROJECT_NAME}-grafana 3000:80 -n monitoring
# kubectl --kubeconfig=$KUBECONFIG_PATH port-forward svc/jaeger 16686:16686 -n tracing
ENVFILE

log_ok ".observability-env escrito en: $OBS_ENV_FILE"

# ---------------------------------------------------------------------------
# Paso 7 — Verificación y checklist
# ---------------------------------------------------------------------------
HEADER "Paso 7 — Verificación"

wait_running() {
  local ns="$1" label="$2" timeout=120 elapsed=0
  log "Esperando pods $label en namespace $ns..."
  until kubectl get pods -n "$ns" -l "$label" \
        --field-selector=status.phase=Running --no-headers 2>/dev/null | grep -q .; do
    sleep 5; elapsed=$((elapsed+5))
    [[ $elapsed -ge $timeout ]] && { log_err "Timeout esperando $label en $ns"; return 1; }
  done
  log_ok "Pods $label en $ns están Running."
}

wait_running monitoring "app.kubernetes.io/name=prometheus"
wait_running monitoring "app.kubernetes.io/name=grafana"
wait_running monitoring "app=${PROJECT_NAME}-otel-collector"
wait_running monitoring "app.kubernetes.io/name=fluent-bit"
wait_running tracing    "app.kubernetes.io/name=jaeger"

echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║           Stack de Observabilidad listo — ${PROJECT_NAME}           "
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""
echo " ✓ kube-prometheus-stack   → namespace monitoring"
echo " ✓ Jaeger all-in-one       → namespace tracing"
echo " ✓ OTEL Collector          → ${PROJECT_NAME}-otel-collector.monitoring:4317"
echo " ✓ Loki + Fluent Bit       → namespace monitoring"
echo ""
echo " Port-forwards (ejecutar en terminales separadas):"
echo "   kubectl --kubeconfig=$KUBECONFIG_PATH port-forward svc/prometheus-operated 9090:9090 -n monitoring"
echo "   kubectl --kubeconfig=$KUBECONFIG_PATH port-forward svc/${PROJECT_NAME}-grafana 3000:80 -n monitoring"
echo "   kubectl --kubeconfig=$KUBECONFIG_PATH port-forward svc/jaeger 16686:16686 -n tracing"
echo ""
echo " Prometheus  → http://localhost:9090"
echo " Grafana     → http://localhost:3000  (admin/admin)"
echo " Jaeger UI   → http://localhost:16686"
echo ""
echo " Endpoints en: $OBS_ENV_FILE"
echo ""
