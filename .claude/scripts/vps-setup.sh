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
#   services    Instala servicios como systemd: MongoDB 8, Kafka 3.7, Gitea 1.22,
#               SonarQube LTS, Jenkins LTS, WireMock 3.9, Narayana LRA Coordinator
#   k3s         Instala K3s nativo + ArgoCD + descarga kubeconfig al host
#   floci       Instala floci CLI nativo (usa Docker solo para sus contenedores internos)
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
MAVEN_VERSION="3.9.16"
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

echo "[+] GraalVM JDK 25 (native-image para floci)..."
GRAALVM_DIR="/opt/graalvm-25"
if [[ ! -x "${GRAALVM_DIR}/bin/native-image" ]]; then
  wget -qO /tmp/graalvm.tar.gz \
    "https://download.oracle.com/graalvm/25/latest/graalvm-jdk-25_linux-x64_bin.tar.gz"
  sudo mkdir -p "${GRAALVM_DIR}"
  sudo tar -xzf /tmp/graalvm.tar.gz -C "${GRAALVM_DIR}" --strip-components=1
  rm /tmp/graalvm.tar.gz
fi
${GRAALVM_DIR}/bin/java -version 2>&1 | head -1
${GRAALVM_DIR}/bin/native-image --version 2>&1 | head -1

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

# ── 2. MongoDB / FerretDB (kernel-aware) ─────────────────────────────────────
# MongoDB 8+ es incompatible con kernel >= 6.19 (SERVER-121912).
# En kernels afectados se instala FerretDB como proxy MongoDB-compatible.
echo "[MongoDB] Detectando versión de kernel..."
KERNEL_MAJOR=\$(uname -r | cut -d. -f1)
KERNEL_MINOR=\$(uname -r | cut -d. -f2)

if [[ \$KERNEL_MAJOR -gt 6 ]] || { [[ \$KERNEL_MAJOR -eq 6 ]] && [[ \$KERNEL_MINOR -ge 19 ]]; }; then
  echo "[MongoDB] Kernel \$(uname -r) >= 6.19 — MongoDB incompatible (SERVER-121912)."
  echo "[MongoDB] Instalando FerretDB (proxy MongoDB-compatible sobre PostgreSQL)..."

  FERRETDB_VERSION="1.24.0"
  if ! command -v ferretdb &>/dev/null; then
    # Intentar descarga directa del binario; si falla, probar el tarball
    sudo wget -qO /usr/local/bin/ferretdb \
      "https://github.com/FerretDB/FerretDB/releases/download/v\${FERRETDB_VERSION}/ferretdb-linux-amd64" \
    || {
      sudo wget -qO /tmp/ferretdb.tar.gz \
        "https://github.com/FerretDB/FerretDB/releases/download/v\${FERRETDB_VERSION}/ferretdb_\${FERRETDB_VERSION}_linux_amd64.tar.gz"
      sudo tar -xzf /tmp/ferretdb.tar.gz -C /usr/local/bin/ ferretdb 2>/dev/null \
        || sudo tar -xzf /tmp/ferretdb.tar.gz --wildcards -C /usr/local/bin/ '*/ferretdb' --strip-components=1
      rm -f /tmp/ferretdb.tar.gz
    }
    sudo chmod +x /usr/local/bin/ferretdb
  fi
  ferretdb --version 2>/dev/null | head -1 || true

  id "ferretdb" &>/dev/null || sudo useradd -r -s /bin/false "ferretdb"
  sudo mkdir -p /var/lib/ferretdb
  sudo chown ferretdb:ferretdb /var/lib/ferretdb

  sudo tee /etc/systemd/system/mongod.service > /dev/null <<EOF
[Unit]
Description=FerretDB (MongoDB-compatible, SQLite backend)
After=network.target

[Service]
Type=simple
User=ferretdb
ExecStart=/usr/local/bin/ferretdb \\
  --handler=sqlite \\
  --sqlite-url=file:/var/lib/ferretdb/ \\
  --state-dir=/var/lib/ferretdb \\
  --listen-addr=:27017
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

else
  # MongoDB nativo (kernel < 6.19)
  echo "[MongoDB] Instalando MongoDB nativo..."
  if ! command -v mongod &>/dev/null; then
    sudo rm -f /etc/apt/sources.list.d/mongodb-org-*.list \
               /usr/share/keyrings/mongodb-server-*.gpg

    if grep -qc avx /proc/cpuinfo; then
      MONGO_VER="8.0"
      echo "[MongoDB] AVX disponible — instalando MongoDB 8.0"
    else
      MONGO_VER="7.0"
      echo "[MongoDB] Sin AVX (VM KVM) — instalando MongoDB 7.0"
    fi

    curl -fsSL "https://www.mongodb.org/static/pgp/server-\${MONGO_VER}.asc" \
      | sudo gpg --dearmor -o /usr/share/keyrings/mongodb-server-\${MONGO_VER}.gpg
    MONGO_CS=\$(lsb_release -cs)
    curl -sf "https://repo.mongodb.org/apt/ubuntu/dists/\${MONGO_CS}/mongodb-org/\${MONGO_VER}/InRelease" &>/dev/null \
      || MONGO_CS="noble"
    echo "deb [ arch=amd64 signed-by=/usr/share/keyrings/mongodb-server-\${MONGO_VER}.gpg ] \
      https://repo.mongodb.org/apt/ubuntu \${MONGO_CS}/mongodb-org/\${MONGO_VER} multiverse" \
      | sudo tee /etc/apt/sources.list.d/mongodb-org-\${MONGO_VER}.list
    sudo apt-get update -qq
    sudo apt-get install -y -qq mongodb-org
  fi
fi

sudo systemctl daemon-reload
sudo systemctl enable --now mongod
sleep 3
systemctl is-active mongod && echo "[OK] MongoDB/FerretDB activo." || echo "[WARN] mongod no activo (revisar: journalctl -u mongod -n 20)."

# ── 3. Apache Kafka 3.9 (KRaft, sin ZooKeeper) ──────────────────────────────
echo "[Kafka] Instalando Apache Kafka 3.9..."
KAFKA_VERSION="3.9.2"
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

# Elasticsearch embebido requiere vm.max_map_count >= 524288
sudo sysctl -w vm.max_map_count=524288 > /dev/null
grep -q 'vm.max_map_count' /etc/sysctl.conf \
  || echo 'vm.max_map_count=524288' | sudo tee -a /etc/sysctl.conf > /dev/null

sudo apt-get install -y -qq openjdk-17-jdk

if [[ ! -d "\$SONAR_DIR" ]]; then
  wget -qO /tmp/sonarqube.zip \
    "https://binaries.sonarsource.com/Distribution/sonarqube/sonarqube-\${SONAR_VERSION}.zip"
  sudo unzip -q /tmp/sonarqube.zip -d /opt/
  sudo ln -sfn "/opt/sonarqube-\${SONAR_VERSION}" "\$SONAR_DIR"
  rm /tmp/sonarqube.zip
fi
sudo chown -R "\$SONAR_USER:\$SONAR_USER" "/opt/sonarqube-\${SONAR_VERSION}"

# Kafka ocupa el puerto 9092; reemplazar la línea (comentada o activa) con el valor correcto
sudo sed -i '/sonar\.embeddedDatabase\.port/d' "\$SONAR_DIR/conf/sonar.properties"
echo 'sonar.embeddedDatabase.port=9094' | sudo tee -a "\$SONAR_DIR/conf/sonar.properties"

sudo tee /etc/systemd/system/sonarqube.service > /dev/null <<EOF
[Unit]
Description=SonarQube
After=network.target

[Service]
Type=forking
User=\$SONAR_USER
Environment=JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
Environment="PATH=/usr/lib/jvm/java-17-openjdk-amd64/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=\$SONAR_DIR/bin/linux-x86-64/sonar.sh start
ExecStop=\$SONAR_DIR/bin/linux-x86-64/sonar.sh stop
PIDFile=\$SONAR_DIR/bin/linux-x86-64/SonarQube.pid
TimeoutStartSec=300
Restart=on-failure
LimitNOFILE=65536
LimitNPROC=8192

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now sonarqube
# SonarQube tarda 60-120 s en arrancar (Elasticsearch embebido)
for _i in \$(seq 1 12); do
  systemctl is-active --quiet sonarqube && break || sleep 10
done
systemctl is-active sonarqube && echo "[OK] SonarQube activo." || echo "[WARN] SonarQube no activo (revisar: journalctl -u sonarqube -n 30)."

# ── 6. Jenkins LTS ───────────────────────────────────────────────────────────
echo "[Jenkins] Instalando Jenkins LTS..."
if ! command -v jenkins &>/dev/null && ! systemctl list-units --type=service | grep -q jenkins; then
  sudo rm -f /usr/share/keyrings/jenkins-keyring.asc /usr/share/keyrings/jenkins-keyring.gpg \
             /etc/apt/sources.list.d/jenkins.list
  # La clave jenkins.io-2023.key expiró en mar-2026; obtener la vigente del keyserver
  gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys 7198F4B714ABFC68
  gpg --export 7198F4B714ABFC68 | sudo tee /usr/share/keyrings/jenkins-keyring.gpg > /dev/null
  echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.gpg] \
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

# ── 8. Narayana LRA Coordinator (Quarkus standalone, compilado desde fuente) ──
echo "[LRA] Compilando Narayana LRA Coordinator (Quarkus standalone)..."
NARAYANA_VERSION="7.0.0.Final"
LRA_DIR="/opt/lra-coordinator"
LRA_USER="lra"

id "\$LRA_USER" &>/dev/null || sudo useradd -r -s /bin/false "\$LRA_USER"
sudo mkdir -p "\$LRA_DIR"

if [[ ! -f "\$LRA_DIR/lra-coordinator.jar" ]]; then
  echo "[LRA] Clonando narayana \${NARAYANA_VERSION} (rama shallow)..."
  sudo rm -rf /tmp/narayana-src
  git clone --depth=1 --branch "\${NARAYANA_VERSION}" \
    https://github.com/jbosstm/narayana.git /tmp/narayana-src

  echo "[LRA] Localizando módulo lra/coordinator..."
  LRA_MODULE=\$(find /tmp/narayana-src -path "*/lra/coordinator/pom.xml" \
    ! -path "*/test*" 2>/dev/null | head -1 | sed "s|/tmp/narayana-src/||;s|/pom.xml||")
  [[ -n "\$LRA_MODULE" ]] || { echo "[ERROR] Módulo lra/coordinator no encontrado en el repo"; exit 1; }
  echo "[LRA] Módulo encontrado: \${LRA_MODULE}"

  echo "[LRA] Instalando POMs padre y compilando coordinator (5-10 min)..."
  # mvn -pl falla porque el módulo no está en el reactor por defecto;
  # se instalan root + padres intermedios con -N (non-recursive) para que
  # maven pueda resolver el módulo coordinator de forma standalone.
  LRA_GRANDPARENT=\$(dirname \$(dirname "\$LRA_MODULE"))
  LRA_PARENT=\$(dirname "\$LRA_MODULE")

  cd /tmp/narayana-src
  JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 mvn install -N -q -DskipTests

  [[ "\$LRA_GRANDPARENT" != "." ]] && \
    (cd /tmp/narayana-src/"\$LRA_GRANDPARENT" && \
      JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 mvn install -N -q -DskipTests)

  (cd /tmp/narayana-src/"\$LRA_PARENT" && \
    JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 mvn install -N -q -DskipTests)

  (cd /tmp/narayana-src/"\$LRA_MODULE" && \
    JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 mvn package \
      -DskipTests -Dquarkus.package.type=uber-jar -q)

  LRA_JAR=\$(find /tmp/narayana-src/\${LRA_MODULE}/target \
    -maxdepth 1 -name "*-runner.jar" 2>/dev/null | head -1)
  [[ -n "\$LRA_JAR" ]] || LRA_JAR=\$(find /tmp/narayana-src/\${LRA_MODULE}/target \
    -maxdepth 1 -name "*.jar" ! -name "*sources*" ! -name "*javadoc*" 2>/dev/null | tail -1)
  [[ -n "\$LRA_JAR" ]] || { echo "[ERROR] JAR del LRA Coordinator no encontrado en target/"; exit 1; }

  sudo cp "\$LRA_JAR" "\$LRA_DIR/lra-coordinator.jar"
  sudo rm -rf /tmp/narayana-src
  echo "[LRA] JAR instalado en \$LRA_DIR/lra-coordinator.jar"
fi

sudo chown -R "\$LRA_USER:\$LRA_USER" "\$LRA_DIR"

sudo tee /etc/systemd/system/lra-coordinator.service > /dev/null <<EOF
[Unit]
Description=Narayana LRA Coordinator
After=network.target

[Service]
Type=simple
User=\$LRA_USER
Environment=QUARKUS_HTTP_PORT=50000
ExecStart=/usr/bin/java -jar \$LRA_DIR/lra-coordinator.jar
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now lra-coordinator
# JVM tarda ~15-20 s en arrancar; reintentar hasta 30 s
for _i in \$(seq 1 6); do
  systemctl is-active --quiet lra-coordinator && break || sleep 5
done
systemctl is-active lra-coordinator \
  && echo "[OK] LRA Coordinator activo." \
  || echo "[WARN] LRA Coordinator no activo (revisar: journalctl -u lra-coordinator -n 20)."

# ── 9. PostgreSQL 16 ──────────────────────────────────────────────────────────
echo "[PostgreSQL] Instalando PostgreSQL 16..."
if ! command -v psql &>/dev/null; then
  # Ubuntu 26.04 no trae postgresql-16 en apt; usar repositorio oficial PGDG
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    | sudo gpg --dearmor -o /usr/share/keyrings/postgresql.gpg
  PGDG_CS=\$(lsb_release -cs)
  # Si el codename no existe aún en PGDG (distro muy nueva) caer a noble
  curl -sf "https://apt.postgresql.org/pub/repos/apt/dists/\${PGDG_CS}-pgdg/InRelease" &>/dev/null \
    || PGDG_CS="noble"
  echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] https://apt.postgresql.org/pub/repos/apt \${PGDG_CS}-pgdg main" \
    | sudo tee /etc/apt/sources.list.d/pgdg.list > /dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq postgresql-16
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
# floci = CLI nativo (GraalVM) que gestiona un container Docker interno.
# Systemd usa Type=oneshot + RemainAfterExit para que `systemctl is-active floci`
# devuelva "active" después de que `floci start` termina (el container sigue vivo).
cmd_floci() {
  require_vm_ip
  header "Instalando y levantando floci en $VM_IP"

  ssh_vps "bash -s" <<'REMOTE'
set -euo pipefail

echo "[floci] Compilando binario nativo desde fuente..."
if ! command -v floci &>/dev/null; then
  sudo rm -rf /tmp/floci-src
  git clone --depth=1 https://github.com/floci-io/floci-cli /tmp/floci-src

  echo "[floci] Compilando con GraalVM native-image (5-10 min)..."
  cd /tmp/floci-src
  JAVA_HOME=/opt/graalvm-25 \
    mvn clean package -Dnative -DskipTests -q

  sudo cp target/floci /usr/local/bin/floci
  sudo chmod +x /usr/local/bin/floci
  cd /
  sudo rm -rf /tmp/floci-src
fi
floci --version 2>/dev/null || true

echo "[floci] Creando unidad systemd..."
sudo tee /etc/systemd/system/floci.service > /dev/null <<EOF
[Unit]
Description=Floci cloud emulator (LocalStack-compatible)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/floci start
ExecStop=/usr/local/bin/floci stop

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable floci

# Si ya hay un container corriendo, detenerlo antes de (re)iniciar
floci stop 2>/dev/null || true
sudo systemctl start floci

# Esperar health endpoint (hasta 60 s)
for i in $(seq 1 30); do
  curl -sf http://localhost:4566/_localstack/health &>/dev/null && break || sleep 2
done
systemctl is-active floci && echo "[OK] floci activo (systemctl is-active devuelve active)." \
  || echo "[WARN] floci no activo (revisar: journalctl -u floci -n 20)."
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
for svc in mongod kafka gitea sonarqube jenkins wiremock lra-coordinator postgresql k3s; do
  state=$(systemctl is-active "$svc" 2>/dev/null)
  [[ "$state" == "unknown" || -z "$state" ]] && state="no instalado"
  printf "  %-22s %s\n" "$svc" "$state"
done

echo ""
echo "── Docker / floci ─────────────────────────────────────────"
docker ps --format "  {{.Names}}\t{{.Status}}" 2>/dev/null || echo "  Docker no disponible"

echo ""
echo "── Puertos en escucha ─────────────────────────────────────"
ss -tlnp 2>/dev/null | grep -E ':(22|80|443|2222|3000|4566|5432|6443|8080|9000|9090|9092|9999|16686|27017|29092|50000)\s' \
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
