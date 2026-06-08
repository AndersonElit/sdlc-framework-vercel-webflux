#!/usr/bin/env bash
# vps-setup.sh — Instala y configura todos los servicios del framework SDLC en el VPS
#               Ubuntu 26.04 LTS como unidades systemd (PLAN-VPS-MIGRATION.md § Paso 4).
#
# Prerequisito: la VM ya debe existir y estar configurada con qemu-vps.sh setup.
#
# Uso: ./vps-setup.sh <COMANDO> [OPCIONES]
#
# Comandos:
#   prereqs     Instala herramientas de sistema (Java 21, Docker, AWS CLI, kubectl, helm,
#               terraform, argocd CLI, Maven, curl, jq, yq, git, python3)
#   services    Instala servicios como systemd: MongoDB 7, Kafka 3.7, Gitea 1.22,
#               SonarQube LTS, Jenkins LTS, WireMock 3.9, Narayana LRA Coordinator
#   k3s         Instala K3s nativo + ArgoCD + descarga kubeconfig al host
#   floci       Instala floci CLI + levanta contenedor floci/floci:latest (Docker)
#   status      Muestra estado de todos los servicios
#   all         Ejecuta prereqs → services → floci → k3s en orden
#
# Opciones:
#   --vm-ip   IP    IP del VPS / VM                   (requerido)
#   --vm-user USER  Usuario SSH                        (default: ubuntu)
#   --ssh-key FILE  Clave SSH privada                  (default: ~/.ssh/id_ed25519)
#   --project NAME  Slug del proyecto para Gitea org   (default: sdlc)
#
# Ejemplos:
#   ./vps-setup.sh prereqs  --vm-ip 192.168.122.50
#   ./vps-setup.sh services --vm-ip 192.168.122.50
#   ./vps-setup.sh k3s      --vm-ip 192.168.122.50
#   ./vps-setup.sh all      --vm-ip 192.168.122.50 --project mibanco

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()   { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()     { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()   { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()    { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
header() { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; }
die()    { err "$*"; exit 1; }

# ─── defaults ────────────────────────────────────────────────────────────────
VM_IP=""
VM_USER="ubuntu"
SSH_KEY="$HOME/.ssh/id_ed25519"
PROJECT_NAME="sdlc"

COMMAND="${1:-help}"
shift || true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm-ip)    VM_IP="$2";      shift 2 ;;
    --vm-user)  VM_USER="$2";    shift 2 ;;
    --ssh-key)  SSH_KEY="$2";    shift 2 ;;
    --project)  PROJECT_NAME="$2"; shift 2 ;;
    *) die "Opción desconocida: $1" ;;
  esac
done

# ─── helpers ─────────────────────────────────────────────────────────────────
require_vm_ip() {
  [[ -n "$VM_IP" ]] || die "Falta --vm-ip <IP>. Ejemplo: ./vps-setup.sh $COMMAND --vm-ip 192.168.122.50"
}

ssh_vps() {
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
      -o BatchMode=yes "${VM_USER}@${VM_IP}" "$@"
}

scp_to_vps() {
  scp -i "$SSH_KEY" -o StrictHostKeyChecking=no "$1" "${VM_USER}@${VM_IP}:$2"
}

check_service() {
  local svc="$1"
  if ssh_vps "systemctl is-active --quiet '$svc'" 2>/dev/null; then
    ok "$svc activo"
  else
    warn "$svc NO activo"
  fi
}

# ─── COMANDO: help ────────────────────────────────────────────────────────────
cmd_help() {
  sed -n '2,/^set -/{ /^set -/d; s/^# \{0,1\}//; p }' "$0"
}

# ─── COMANDO: prereqs ─────────────────────────────────────────────────────────
cmd_prereqs() {
  require_vm_ip
  header "Instalando prerequisitos del sistema en $VM_IP"

  ssh_vps "bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "[1/10] Actualizando índice apt..."
sudo apt-get update -qq

echo "[2/10] Paquetes base..."
sudo apt-get install -y -qq \
  curl wget git jq python3 python3-pip unzip gnupg lsb-release \
  ca-certificates apt-transport-https software-properties-common

echo "[3/10] Java 21 LTS..."
sudo apt-get install -y -qq openjdk-21-jdk
java -version 2>&1 | head -1

echo "[4/10] Maven 3.9+..."
MAVEN_VERSION="3.9.9"
if ! mvn --version &>/dev/null 2>&1; then
  wget -qO /tmp/maven.tar.gz \
    "https://dlcdn.apache.org/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz"
  sudo tar -xzf /tmp/maven.tar.gz -C /opt
  sudo ln -sfn /opt/apache-maven-${MAVEN_VERSION} /opt/maven
  sudo ln -sfn /opt/maven/bin/mvn /usr/local/bin/mvn
  rm /tmp/maven.tar.gz
fi
mvn --version | head -1

echo "[5/10] yq..."
YQ_VERSION="v4.44.2"
if ! yq --version &>/dev/null 2>&1; then
  sudo wget -qO /usr/local/bin/yq \
    "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64"
  sudo chmod +x /usr/local/bin/yq
fi
yq --version

echo "[6/10] kubectl..."
if ! kubectl version --client &>/dev/null 2>&1; then
  KUBECTL_VERSION=$(curl -sL https://dl.k8s.io/release/stable.txt)
  sudo curl -sLo /usr/local/bin/kubectl \
    "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
  sudo chmod +x /usr/local/bin/kubectl
fi
kubectl version --client --short 2>/dev/null || kubectl version --client

echo "[7/10] Helm..."
if ! helm version &>/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
helm version --short

echo "[8/10] Terraform..."
if ! terraform version &>/dev/null 2>&1; then
  wget -qO /tmp/tf.zip \
    "$(curl -sL https://releases.hashicorp.com/terraform/index.json \
       | python3 -c "import json,sys; d=json.load(sys.stdin); v=sorted(d['versions'].keys())[-1]; \
         print([u for u in d['versions'][v]['builds'] if 'linux_amd64' in u['url']][0]['url'])")"
  sudo unzip -q /tmp/tf.zip -d /usr/local/bin/
  rm /tmp/tf.zip
fi
terraform version | head -1

echo "[9/10] AWS CLI v2..."
if ! aws --version &>/dev/null 2>&1; then
  curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp/
  sudo /tmp/aws/install
  rm -rf /tmp/aws /tmp/awscliv2.zip
fi
aws --version

echo "[10/10] Liquibase..."
LIQUIBASE_VERSION="4.29.2"
if ! command -v liquibase &>/dev/null; then
  wget -qO /tmp/liquibase.tar.gz \
    "https://github.com/liquibase/liquibase/releases/download/v${LIQUIBASE_VERSION}/liquibase-${LIQUIBASE_VERSION}.tar.gz"
  sudo mkdir -p /opt/liquibase
  sudo tar -xzf /tmp/liquibase.tar.gz -C /opt/liquibase
  sudo ln -sfn /opt/liquibase/liquibase /usr/local/bin/liquibase
  rm /tmp/liquibase.tar.gz
fi
liquibase --version 2>&1 | head -1

echo "[OK] Prerequisitos instalados."
REMOTE
  ok "Prerequisitos completados en $VM_IP"
}

# ─── COMANDO: services ────────────────────────────────────────────────────────
cmd_services() {
  require_vm_ip
  header "Instalando servicios systemd en $VM_IP"

  local project="$PROJECT_NAME"

  ssh_vps "bash -s" <<REMOTE
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ── 1. Docker (requerido por floci) ──────────────────────────────────────────
echo "[Docker] Instalando Docker Engine..."
if ! command -v docker &>/dev/null; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
    https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
  sudo usermod -aG docker $VM_USER
  sudo systemctl enable --now docker
fi
docker --version

# ── 2. MongoDB 7 ─────────────────────────────────────────────────────────────
echo "[MongoDB] Instalando MongoDB 7..."
if ! command -v mongod &>/dev/null; then
  curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc \
    | sudo gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg
  echo "deb [ arch=amd64 signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] \
    https://repo.mongodb.org/apt/ubuntu noble/mongodb-org/7.0 multiverse" \
    | sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list
  sudo apt-get update -qq
  sudo apt-get install -y -qq mongodb-org
fi
sudo systemctl enable --now mongod
systemctl is-active mongod && echo "[OK] MongoDB activo." || echo "[WARN] MongoDB no activo."

# ── 3. Apache Kafka 3.7 (KRaft, sin ZooKeeper) ──────────────────────────────
echo "[Kafka] Instalando Apache Kafka 3.7..."
KAFKA_VERSION="3.7.2"
KAFKA_DIR="/opt/kafka"
KAFKA_USER="kafka"

if [[ ! -d "\$KAFKA_DIR" ]]; then
  wget -qO /tmp/kafka.tgz \
    "https://downloads.apache.org/kafka/\${KAFKA_VERSION}/kafka_2.13-\${KAFKA_VERSION}.tgz"
  sudo tar -xzf /tmp/kafka.tgz -C /opt
  sudo ln -sfn "/opt/kafka_2.13-\${KAFKA_VERSION}" "\$KAFKA_DIR"
  rm /tmp/kafka.tgz
fi

id "\$KAFKA_USER" &>/dev/null || sudo useradd -r -s /bin/false "\$KAFKA_USER"
sudo chown -R "\$KAFKA_USER:\$KAFKA_USER" "\$KAFKA_DIR"

KAFKA_DATA="/var/lib/kafka"
sudo mkdir -p "\$KAFKA_DATA/kraft-combined-logs"
sudo chown -R "\$KAFKA_USER:\$KAFKA_USER" "\$KAFKA_DATA"

# Generar UUID del cluster si no existe
CLUSTER_ID_FILE="/var/lib/kafka/.cluster_id"
if [[ ! -f "\$CLUSTER_ID_FILE" ]]; then
  CLUSTER_ID=\$("\$KAFKA_DIR/bin/kafka-storage.sh" random-uuid)
  echo "\$CLUSTER_ID" | sudo tee "\$CLUSTER_ID_FILE" > /dev/null
fi
CLUSTER_ID=\$(cat "\$CLUSTER_ID_FILE")

# Configuración KRaft
sudo tee "\$KAFKA_DIR/config/kraft/server.properties" > /dev/null <<EOF
node.id=1
process.roles=broker,controller
listeners=INTERNAL://0.0.0.0:9092,EXTERNAL://0.0.0.0:29092,CONTROLLER://0.0.0.0:9093
advertised.listeners=INTERNAL://${VM_IP}:9092,EXTERNAL://${VM_IP}:29092
inter.broker.listener.name=INTERNAL
controller.listener.names=CONTROLLER
listener.security.protocol.map=CONTROLLER:PLAINTEXT,INTERNAL:PLAINTEXT,EXTERNAL:PLAINTEXT
controller.quorum.voters=1@localhost:9093
log.dirs=\$KAFKA_DATA/kraft-combined-logs
offsets.topic.replication.factor=1
transaction.state.log.replication.factor=1
transaction.state.log.min.isr=1
group.initial.rebalance.delay.ms=0
auto.create.topics.enable=true
EOF

# Formatear el log dir con el cluster ID (idempotente)
sudo -u "\$KAFKA_USER" "\$KAFKA_DIR/bin/kafka-storage.sh" format \
  -t "\$CLUSTER_ID" -c "\$KAFKA_DIR/config/kraft/server.properties" --ignore-formatted 2>/dev/null || true

# Unidad systemd
sudo tee /etc/systemd/system/kafka.service > /dev/null <<EOF
[Unit]
Description=Apache Kafka (KRaft)
After=network.target

[Service]
Type=simple
User=\$KAFKA_USER
ExecStart=\$KAFKA_DIR/bin/kafka-server-start.sh \$KAFKA_DIR/config/kraft/server.properties
ExecStop=\$KAFKA_DIR/bin/kafka-server-stop.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now kafka
sleep 3
systemctl is-active kafka && echo "[OK] Kafka activo." || echo "[WARN] Kafka no activo."

# ── 4. Gitea 1.22 ────────────────────────────────────────────────────────────
echo "[Gitea] Instalando Gitea 1.22..."
GITEA_VERSION="1.22.6"
GITEA_BIN="/usr/local/bin/gitea"
GITEA_USER="git"
GITEA_HOME="/var/lib/gitea"

if [[ ! -f "\$GITEA_BIN" ]]; then
  sudo wget -qO "\$GITEA_BIN" \
    "https://github.com/go-gitea/gitea/releases/download/v\${GITEA_VERSION}/gitea-\${GITEA_VERSION}-linux-amd64"
  sudo chmod +x "\$GITEA_BIN"
fi

id "\$GITEA_USER" &>/dev/null || sudo useradd -r -md "\$GITEA_HOME" -s /bin/bash "\$GITEA_USER"
sudo mkdir -p \
  "\$GITEA_HOME/custom/conf" \
  "\$GITEA_HOME/data" \
  "\$GITEA_HOME/log" \
  "/etc/gitea"
sudo chown -R "\$GITEA_USER:\$GITEA_USER" "\$GITEA_HOME"
sudo chmod 750 "\$GITEA_HOME"

# Configuración
sudo -u "\$GITEA_USER" tee "\$GITEA_HOME/custom/conf/app.ini" > /dev/null <<EOF
[server]
HTTP_PORT = 3000
ROOT_URL  = http://${VM_IP}:3000/
SSH_PORT  = 2222
SSH_LISTEN_PORT = 22

[database]
DB_TYPE = sqlite3
PATH    = \$GITEA_HOME/data/gitea.db

[security]
INSTALL_LOCK = true

[log]
MODE  = console
LEVEL = warn
EOF

sudo tee /etc/systemd/system/gitea.service > /dev/null <<EOF
[Unit]
Description=Gitea (Git with a cup of tea)
After=network.target

[Service]
Type=simple
User=\$GITEA_USER
WorkingDirectory=\$GITEA_HOME
ExecStart=\$GITEA_BIN web --config \$GITEA_HOME/custom/conf/app.ini
Restart=on-failure
RestartSec=5
Environment=HOME=\$GITEA_HOME USER=\$GITEA_USER GITEA_WORK_DIR=\$GITEA_HOME

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now gitea
sleep 5

# Crear usuario admin (idempotente)
sudo -u "\$GITEA_USER" "\$GITEA_BIN" admin user create \
  --username gitea-admin --password gitea-admin \
  --email "admin@${project}.local" --admin --must-change-password=false \
  --config "\$GITEA_HOME/custom/conf/app.ini" 2>/dev/null \
  && echo "[OK] Usuario gitea-admin creado." \
  || echo "  gitea-admin ya existe."

# Crear organización del proyecto (idempotente)
curl -sf -u gitea-admin:gitea-admin -X POST "http://localhost:3000/api/v1/orgs" \
  -H "Content-Type: application/json" \
  -d '{"username":"${project}","visibility":"private"}' \
  &>/dev/null && echo "[OK] Org ${project} creada." || true

# Habilitar Package Registry OCI (Gitea 1.22 lo incluye por defecto)
echo "[OK] Package Registry OCI disponible en http://${VM_IP}:3000/${project}."
systemctl is-active gitea && echo "[OK] Gitea activo." || echo "[WARN] Gitea no activo."

# ── 5. SonarQube LTS ─────────────────────────────────────────────────────────
echo "[SonarQube] Instalando SonarQube LTS..."
SONAR_VERSION="10.7.0.96327"
SONAR_DIR="/opt/sonarqube"
SONAR_USER="sonarqube"

id "\$SONAR_USER" &>/dev/null || sudo useradd -r -s /bin/false "\$SONAR_USER"

if [[ ! -d "\$SONAR_DIR" ]]; then
  wget -qO /tmp/sonarqube.zip \
    "https://binaries.sonarsource.com/Distribution/sonarqube/sonarqube-\${SONAR_VERSION}.zip"
  sudo unzip -q /tmp/sonarqube.zip -d /opt/
  sudo ln -sfn "/opt/sonarqube-\${SONAR_VERSION}" "\$SONAR_DIR"
  rm /tmp/sonarqube.zip
fi
sudo chown -R "\$SONAR_USER:\$SONAR_USER" "\$SONAR_DIR"

sudo tee /etc/systemd/system/sonarqube.service > /dev/null <<EOF
[Unit]
Description=SonarQube
After=network.target

[Service]
Type=forking
User=\$SONAR_USER
ExecStart=\$SONAR_DIR/bin/linux-x86-64/sonar.sh start
ExecStop=\$SONAR_DIR/bin/linux-x86-64/sonar.sh stop
PIDFile=\$SONAR_DIR/bin/linux-x86-64/.SonarQube.pid
Restart=on-failure
LimitNOFILE=65536
LimitNPROC=8192

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now sonarqube
sleep 5
systemctl is-active sonarqube && echo "[OK] SonarQube activo." || echo "[WARN] SonarQube no activo (puede tardar 1-2 min en arrancar)."

# ── 6. Jenkins LTS ───────────────────────────────────────────────────────────
echo "[Jenkins] Instalando Jenkins LTS..."
if ! command -v jenkins &>/dev/null && ! systemctl list-units --type=service | grep -q jenkins; then
  curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key \
    | sudo tee /usr/share/keyrings/jenkins-keyring.asc > /dev/null
  echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] \
    https://pkg.jenkins.io/debian-stable binary/" \
    | sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq jenkins
fi
sudo systemctl enable --now jenkins
sleep 3
systemctl is-active jenkins && echo "[OK] Jenkins activo." || echo "[WARN] Jenkins no activo."

# ── 7. WireMock 3.9 (JAR standalone) ─────────────────────────────────────────
echo "[WireMock] Instalando WireMock 3.9..."
WIREMOCK_VERSION="3.9.1"
WIREMOCK_JAR="/opt/wiremock/wiremock.jar"
WIREMOCK_USER="wiremock"

id "\$WIREMOCK_USER" &>/dev/null || sudo useradd -r -s /bin/false "\$WIREMOCK_USER"
sudo mkdir -p /opt/wiremock
if [[ ! -f "\$WIREMOCK_JAR" ]]; then
  sudo wget -qO "\$WIREMOCK_JAR" \
    "https://repo1.maven.org/maven2/org/wiremock/wiremock-standalone/\${WIREMOCK_VERSION}/wiremock-standalone-\${WIREMOCK_VERSION}.jar"
fi
sudo chown -R "\$WIREMOCK_USER:\$WIREMOCK_USER" /opt/wiremock

sudo tee /etc/systemd/system/wiremock.service > /dev/null <<EOF
[Unit]
Description=WireMock Standalone
After=network.target

[Service]
Type=simple
User=\$WIREMOCK_USER
ExecStart=/usr/bin/java -jar \$WIREMOCK_JAR --port 9999 --root-dir /opt/wiremock/mappings
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now wiremock
sleep 2
systemctl is-active wiremock && echo "[OK] WireMock activo." || echo "[WARN] WireMock no activo."

# ── 8. Narayana LRA Coordinator (JAR standalone) ──────────────────────────────
echo "[LRA] Instalando Narayana LRA Coordinator..."
LRA_VERSION="7.0.3.Final"
LRA_JAR="/opt/lra-coordinator/lra-coordinator.jar"
LRA_USER="lra"

id "\$LRA_USER" &>/dev/null || sudo useradd -r -s /bin/false "\$LRA_USER"
sudo mkdir -p /opt/lra-coordinator
if [[ ! -f "\$LRA_JAR" ]]; then
  sudo wget -qO "\$LRA_JAR" \
    "https://repo1.maven.org/maven2/org/jboss/narayana/lra/lra-coordinator-quarkus/\${LRA_VERSION}/lra-coordinator-quarkus-\${LRA_VERSION}-runner.jar"
fi
sudo chown -R "\$LRA_USER:\$LRA_USER" /opt/lra-coordinator

sudo tee /etc/systemd/system/lra-coordinator.service > /dev/null <<EOF
[Unit]
Description=Narayana LRA Coordinator
After=network.target

[Service]
Type=simple
User=\$LRA_USER
ExecStart=/usr/bin/java -jar \$LRA_JAR -Dquarkus.http.port=50000
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now lra-coordinator
sleep 2
systemctl is-active lra-coordinator && echo "[OK] LRA Coordinator activo." || echo "[WARN] LRA Coordinator no activo."

# ── 9. PostgreSQL 16 ──────────────────────────────────────────────────────────
echo "[PostgreSQL] Instalando PostgreSQL 16..."
if ! command -v psql &>/dev/null; then
  sudo apt-get install -y -qq postgresql-16 postgresql-contrib-16
fi
# Escuchar en todas las interfaces para que los pods K3s accedan vía VPS_IP
sudo sed -i "s|^#listen_addresses.*|listen_addresses = '*'|" \
  /etc/postgresql/16/main/postgresql.conf
# Permitir conexiones desde cualquier IP (autenticación por contraseña)
echo "host  all  all  0.0.0.0/0  scram-sha-256" \
  | sudo tee -a /etc/postgresql/16/main/pg_hba.conf > /dev/null
sudo systemctl enable --now postgresql
sleep 2
systemctl is-active postgresql && echo "[OK] PostgreSQL 16 activo." || echo "[WARN] PostgreSQL no activo."

echo ""
echo "[OK] Todos los servicios instalados en el VPS."
REMOTE

  ok "Instalación de servicios completada en $VM_IP"
}

# ─── COMANDO: floci ───────────────────────────────────────────────────────────
cmd_floci() {
  require_vm_ip
  header "Instalando y levantando floci en $VM_IP"

  ssh_vps "bash -s" <<'REMOTE'
set -euo pipefail

echo "[floci] Instalando floci CLI..."
if ! command -v floci &>/dev/null; then
  curl -fsSL https://floci.io/install.sh | sh
fi
floci --version 2>/dev/null || true

echo "[floci] Iniciando contenedor floci/floci:latest..."
floci start 2>/dev/null || docker run -d \
  --name floci \
  --restart unless-stopped \
  -p 4566:4566 \
  -p 5000-5099:5000-5099 \
  -p 5101-6499:5101-6499 \
  -p 6501-8000:6501-8000 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e DOCKER_NETWORK=bridge \
  floci/floci:latest

# Esperar a que responda
for i in $(seq 1 30); do
  if curl -sf http://localhost:4566/_localstack/health &>/dev/null; then
    echo "[OK] floci respondiendo en http://localhost:4566."
    break
  fi
  sleep 2
done
REMOTE

  ok "floci levantado en $VM_IP:4566"
}

# ─── COMANDO: k3s ─────────────────────────────────────────────────────────────
cmd_k3s() {
  require_vm_ip
  header "Instalando K3s nativo en $VM_IP"

  local kubeconfig_dir="$HOME/.kube"
  mkdir -p "$kubeconfig_dir"

  ssh_vps "bash -s" <<REMOTE
set -euo pipefail

echo "[K3s] Instalando K3s nativo..."
if ! command -v k3s &>/dev/null; then
  curl -sfL https://get.k3s.io | sh -
fi
sudo systemctl enable --now k3s
sleep 5

echo "[K3s] Estado del cluster:"
sudo k3s kubectl get nodes

echo "[K3s] Copiando kubeconfig a /home/${VM_USER}/.kube/config..."
mkdir -p /home/${VM_USER}/.kube
sudo cp /etc/rancher/k3s/k3s.yaml /home/${VM_USER}/.kube/config
sudo sed -i "s|127.0.0.1|${VM_IP}|g" /home/${VM_USER}/.kube/config
sudo chown ${VM_USER}:${VM_USER} /home/${VM_USER}/.kube/config
chmod 600 /home/${VM_USER}/.kube/config

echo "[K3s] Instalando Helm repos (ArgoCD, Prometheus, Grafana, Jaeger, Fluent)..."
export KUBECONFIG=/home/${VM_USER}/.kube/config
helm repo add argo         https://argoproj.github.io/argo-helm         2>/dev/null || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add grafana      https://grafana.github.io/helm-charts         2>/dev/null || true
helm repo add jaegertracing https://jaegertracing.github.io/helm-charts  2>/dev/null || true
helm repo add fluent       https://fluent.github.io/helm-charts          2>/dev/null || true
helm repo update

echo "[ArgoCD] Instalando ArgoCD via Helm..."
kubectl create namespace argocd 2>/dev/null || true
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --set server.service.type=NodePort \
  --set server.service.nodePortHttp=30080 \
  --set server.service.nodePortHttps=30443 \
  --wait --timeout 5m

echo "[OK] K3s + ArgoCD instalados."
kubectl get nodes
kubectl get pods -n argocd
REMOTE

  # Descargar kubeconfig al host
  info "Descargando kubeconfig de K3s al host..."
  scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
    "${VM_USER}@${VM_IP}:/home/${VM_USER}/.kube/config" \
    "$kubeconfig_dir/config-k3s-vps"

  # Renombrar contexto
  sed -i "s|default|k3s-vps|g" "$kubeconfig_dir/config-k3s-vps" 2>/dev/null || true

  ok "Kubeconfig descargado: $kubeconfig_dir/config-k3s-vps"
  ok "Usar: kubectl --kubeconfig $kubeconfig_dir/config-k3s-vps get nodes"
}

# ─── COMANDO: status ──────────────────────────────────────────────────────────
cmd_status() {
  require_vm_ip
  header "Estado de servicios en $VM_IP"

  ssh_vps "bash -s" <<'REMOTE'
echo ""
echo "── Servicios systemd ──────────────────────────────────────"
for svc in mongod kafka gitea sonarqube jenkins wiremock lra-coordinator k3s; do
  state=$(systemctl is-active "$svc" 2>/dev/null || echo "no instalado")
  printf "  %-22s %s\n" "$svc" "$state"
done

echo ""
echo "── Docker / floci ─────────────────────────────────────────"
docker ps --format "  {{.Names}}\t{{.Status}}" 2>/dev/null || echo "  Docker no disponible"

echo ""
echo "── Puertos en escucha ─────────────────────────────────────"
ss -tlnp 2>/dev/null | grep -E ':(22|80|443|2222|3000|4566|6443|8080|9000|9090|9092|9999|16686|27017|29092|50000)\s' \
  | awk '{print "  " $4}' | sort -t: -k2 -n || true

echo ""
echo "── Nodos K3s ───────────────────────────────────────────────"
KUBECONFIG=/home/ubuntu/.kube/config kubectl get nodes 2>/dev/null || echo "  K3s no disponible"
REMOTE
}

# ─── COMANDO: all ─────────────────────────────────────────────────────────────
cmd_all() {
  require_vm_ip
  header "Ejecución completa: prereqs → services → floci → k3s"
  cmd_prereqs
  cmd_services
  cmd_floci
  cmd_k3s
  cmd_status
  ok "Configuración completa del VPS en $VM_IP"
}

# ─── dispatcher ───────────────────────────────────────────────────────────────
case "$COMMAND" in
  prereqs)  cmd_prereqs  ;;
  services) cmd_services ;;
  floci)    cmd_floci    ;;
  k3s)      cmd_k3s      ;;
  status)   cmd_status   ;;
  all)      cmd_all      ;;
  help|--help|-h) cmd_help ;;
  *) err "Comando desconocido: $COMMAND"; echo ""; cmd_help; exit 1 ;;
esac
