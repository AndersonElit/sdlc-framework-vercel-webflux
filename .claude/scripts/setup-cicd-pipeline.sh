#!/usr/bin/env bash
#
# setup-cicd-pipeline.sh
# Script unificado para configurar el pipeline CI/CD (Jenkins + ArgoCD GitOps).
# Cada sección es una función autocontenida. Se ejecutan en orden.
#
# Uso:
#   bash .claude/scripts/setup-cicd-pipeline.sh -P <proyecto> -S <svc1,svc2,...> \
#     --vps-ip <IP> [-F <frontend>]
#
#   -P, --project NOMBRE      Slug del proyecto (obligatorio). Nombra la imagen del
#                             controller (<proyecto>-jenkins), el cluster K3s,
#                             la organización Gitea y los recursos de ArgoCD.
#   -S, --services SVC1,SVC2  Lista de microservicios backend separados por coma (obligatorio).
#                             Ejemplo: --services seguridad,clientes,tasas,originacion
#   --vps-ip IP               IP del VPS donde corren Jenkins (systemd), Gitea y K3s. (obligatorio)
#   -F, --frontend NOMBRE     Nombre del repositorio/job del frontend (opcional).
#                             Si se omite no se crea job de frontend.
#                             Ejemplo: --frontend pagofacil-web
#
set -euo pipefail

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
log_ok() { echo "[$(date '+%H:%M:%S')] OK  $*"; }
log_err() { echo "[$(date '+%H:%M:%S')] ERR $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PROJECT_NAME=""
SERVICES=""
FRONTEND_NAME=""
VPS_IP=""
VPS_USER="${VPS_USER:-ubuntu}"
VPS_SSH_KEY="${VPS_SSH_KEY:-$HOME/.ssh/id_ed25519}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -P|--project)  PROJECT_NAME="${2:-}"; shift 2 ;;
    --project=*)   PROJECT_NAME="${1#*=}"; shift ;;
    -S|--services) SERVICES="${2:-}"; shift 2 ;;
    --services=*)  SERVICES="${1#*=}"; shift ;;
    -F|--frontend) FRONTEND_NAME="${2:-}"; shift 2 ;;
    --frontend=*)  FRONTEND_NAME="${1#*=}"; shift ;;
    --vps-ip)      VPS_IP="${2:-}"; shift 2 ;;
    --vps-ip=*)    VPS_IP="${1#*=}"; shift ;;
    --vps-user)    VPS_USER="${2:-}"; shift 2 ;;
    --vps-ssh-key) VPS_SSH_KEY="${2:-}"; shift 2 ;;
    -h|--help)     grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) log_err "Argumento desconocido: $1"; exit 1 ;;
  esac
done
if [[ -z "$PROJECT_NAME" ]]; then
  log_err "Falta el parámetro obligatorio -P/--project."
  exit 1
fi
if [[ -z "$SERVICES" ]]; then
  log_err "Falta el parámetro obligatorio -S/--services (ej: --services seguridad,clientes,tasas)."
  exit 1
fi
if [[ -z "$VPS_IP" ]]; then
  log_err "Falta el parámetro obligatorio --vps-ip."
  exit 1
fi

ORG_SLUG="$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"

ssh_vps() { ssh -i "$VPS_SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
              -o BatchMode=yes "${VPS_USER}@${VPS_IP}" "$@"; }

# Calcular total de jobs esperados (backends + frontend opcional)
EXPECTED_JOB_COUNT=0
IFS=',' read -ra _svc_arr <<< "$SERVICES"
for _svc in "${_svc_arr[@]}"; do
  _svc="${_svc// /}"
  [[ -n "$_svc" ]] && EXPECTED_JOB_COUNT=$((EXPECTED_JOB_COUNT + 1))
done
[[ -n "$FRONTEND_NAME" ]] && EXPECTED_JOB_COUNT=$((EXPECTED_JOB_COUNT + 1))

# ---------------------------------------------------------------------------
# Sección 0 — Generar la Shared Library
# ---------------------------------------------------------------------------
section_0_generar_shared_library() {
  log "=== Sección 0 — Generar la Shared Library ==="

  bash "$SCRIPT_DIR/jenkins-shared-library-builder.sh" -P "$PROJECT_NAME" -o "$PROJECT_ROOT/jenkins-shared-library" --vps-ip "$VPS_IP"

  # Verificación
  local expected_vars=(
    computeImageTag buildBackendService runIntegrationTests runQualityGates
    runSecurityScans buildAndPushImage scanImage bumpImageTag runSmokeTests notify
  )
  for var in "${expected_vars[@]}"; do
    if [[ ! -f "$PROJECT_ROOT/jenkins-shared-library/vars/${var}.groovy" ]]; then
      log_err "Falta vars/${var}.groovy"
      exit 1
    fi
  done
  log_ok "Sección 0 completada — 10 steps vars/ verificados."
}

# ---------------------------------------------------------------------------
# Sección 1 — Construir y publicar la imagen del controller
# ---------------------------------------------------------------------------
section_1_construir_imagen_controller() {
  log "=== Sección 1 — Construir y publicar la imagen del controller ==="

  local docker_dir="$PROJECT_ROOT/jenkins-shared-library/docker"
  local image_name="${PROJECT_NAME}-jenkins"
  local image_tag="latest"

  # Validar prerequisitos
  if [[ ! -f "$docker_dir/Dockerfile" ]]; then
    log_err "Dockerfile no encontrado en $docker_dir. Ejecutá primero la Sección 0."
    exit 1
  fi
  if ! command -v docker &>/dev/null; then
    log_err "Docker no está instalado."
    exit 1
  fi

  local env_name="${DEPLOY_ENV:-dev}"

  # dev (VPS): Jenkins corre como servicio systemd en el VPS.
  # La imagen del controller se construye localmente y se publica en el
  # Gitea Package Registry del VPS para que el agente K3s pueda hacer pull.
  if [[ "$env_name" == "dev" ]]; then
    # Gitea registry: VPS_IP:3000/<org>/<imagen>
    local gitea_registry="${VPS_IP}:3000/${PROJECT_NAME}"
    local remote_image="${gitea_registry}/${image_name}:${image_tag}"

    if [[ ! -f "$docker_dir/Dockerfile" ]]; then
      log_err "Dockerfile no encontrado en $docker_dir."
      exit 1
    fi

    log "Construyendo imagen del controller: $image_name:$image_tag"
    docker build -t "$image_name:$image_tag" "$docker_dir"

    log "Publicando en Gitea Package Registry: $remote_image"
    echo "gitea-admin" | docker login "${VPS_IP}:3000" \
      --username gitea-admin --password-stdin 2>/dev/null || true
    docker tag "$image_name:$image_tag" "$remote_image"
    docker push "$remote_image"

    log_ok "Sección 1 completada — imagen publicada en Gitea registry: $remote_image"
    return 0
  fi

  # staging/prod: Gitea registry o ECR real según variable de entorno
  local registry="${GITEA_REGISTRY:-${ECR_REGISTRY:-}}"
  if [[ -z "$registry" ]]; then
    local tf_dir="$PROJECT_ROOT/terraform/backend/environments/$env_name"
    if [[ -d "$tf_dir" ]]; then
      registry=$(cd "$tf_dir" && terraform output -raw gitea_registry 2>/dev/null || true)
    fi
  fi
  if [[ -z "$registry" ]]; then
    log_err "GITEA_REGISTRY no definido. Exportalo: export GITEA_REGISTRY=<VPS_IP>:3000/<org>"
    exit 1
  fi
  log "Registry: $registry"

  log "Construyendo imagen Docker: $image_name:$image_tag"
  docker build -t "$image_name:$image_tag" "$docker_dir"

  local remote_image="${registry}/${image_name}:${image_tag}"
  log "Publicando: $remote_image"
  docker tag "$image_name:$image_tag" "$remote_image"
  docker push "$remote_image"

  log_ok "Sección 1 completada — Imagen publicada: $remote_image"
}

# ---------------------------------------------------------------------------
# Sección 2 — Bootstrap del cluster (namespace + ServiceAccount IRSA)
# ---------------------------------------------------------------------------
section_2_bootstrap_cluster() {
  log "=== Sección 2 — Bootstrap del cluster ==="

  local env_name="${DEPLOY_ENV:-dev}"

  if ! command -v kubectl &>/dev/null; then
    log_err "kubectl no está instalado."
    exit 1
  fi

  # Determinar directorio Terraform del ambiente
  local tf_dir="$PROJECT_ROOT/terraform/backend/environments/$env_name"
  if [[ ! -d "$tf_dir" ]]; then
    log_err "Directorio de Terraform no encontrado: $tf_dir"
    exit 1
  fi

  # --- dev (K3s nativo en VPS): cluster real, sin IRSA ---
  # Se aplica el RBAC del agente: namespace jenkins + SA jenkins-agent +
  # Role/RoleBinding para smoke tests en el namespace dev.
  if [[ "$env_name" == "dev" ]]; then
    local kubeconfig="$tf_dir/.kube/config-k3s"
    local dev_rbac="$tf_dir/argocd-bootstrap/jenkins-agent-rbac-dev.yaml"
    if [[ ! -f "$kubeconfig" ]]; then
      log_err "Kubeconfig de K3s no encontrado: $kubeconfig. Ejecutá primero base-infrastructure-builder.sh con --vps-ip."
      exit 1
    fi
    if [[ ! -f "$dev_rbac" ]]; then
      log_err "No se encontró $dev_rbac. Regenerá la infra con base-infrastructure-builder.sh."
      exit 1
    fi
    log "Aplicando RBAC del agente al cluster K3s..."
    kubectl --kubeconfig "$kubeconfig" apply -f "$dev_rbac"
    if ! kubectl --kubeconfig "$kubeconfig" get serviceaccount jenkins-agent -n jenkins &>/dev/null; then
      log_err "ServiceAccount 'jenkins-agent' no se creó en namespace 'jenkins'."
      exit 1
    fi
    log_ok "Sección 2 completada — RBAC del agente aplicado en K3s."
    return 0
  fi

  # --- staging/prod (EKS real, IRSA) ---
  local bootstrap_yaml="$PROJECT_ROOT/jenkins-shared-library/bootstrap/jenkins-agent-rbac.yaml"
  if [[ ! -f "$bootstrap_yaml" ]]; then
    log_err "No se encontró $bootstrap_yaml. Ejecutá primero la Sección 0."
    exit 1
  fi

  # Obtener agent_role_arn desde output de Terraform
  log "Leyendo agent_role_arn desde Terraform ($env_name)..."
  local agent_role_arn
  agent_role_arn=$(cd "$tf_dir" && terraform output -raw jenkins_agent_role_arn 2>/dev/null || echo "")
  if [[ -z "$agent_role_arn" ]]; then
    log_err "No se pudo leer jenkins_agent_role_arn de Terraform ($env_name). Aplicá la infra primero."
    exit 1
  fi

  # Sustituir placeholder en el YAML y aplicar
  log "Sustituyendo <JENKINS_AGENT_ROLE_ARN> → $agent_role_arn"
  local rendered_yaml="/tmp/jenkins-agent-rbac-rendered.yaml"
  sed "s|<JENKINS_AGENT_ROLE_ARN>|$agent_role_arn|g" "$bootstrap_yaml" > "$rendered_yaml"

  log "Aplicando manifiesto al cluster EKS ($env_name)..."
  kubectl apply -f "$rendered_yaml"

  # Verificación
  log "Verificando namespace y serviceaccount..."
  if ! kubectl get namespace jenkins &>/dev/null; then
    log_err "Namespace 'jenkins' no se creó."
    exit 1
  fi
  if ! kubectl get serviceaccount jenkins-agent -n jenkins &>/dev/null; then
    log_err "ServiceAccount 'jenkins-agent' no se creó en namespace 'jenkins'."
    exit 1
  fi

  rm -f "$rendered_yaml"
  log_ok "Sección 2 completada — Namespace y ServiceAccount IRSA creados en EKS."
}

# ---------------------------------------------------------------------------
# Sección 3 — Variables de entorno y credenciales al controller (JCasC)
# ---------------------------------------------------------------------------
section_3_variables_credenciales() {
  log "=== Sección 3 — Variables de entorno y credenciales ==="

  local env_name="${DEPLOY_ENV:-dev}"
  local tf_dir="$PROJECT_ROOT/terraform/backend/environments/$env_name"
  local env_file="$PROJECT_ROOT/jenkins-shared-library/docker/.env.jenkins"
  local missing=()

  # --- Helper: leer de terraform output o usar default ---
  tf_output() {
    local key="$1"
    local default="${2:-}"
    local val
    val=$(cd "$tf_dir" && terraform output -raw "$key" 2>/dev/null || echo "")
    if [[ -z "$val" || "$val" == "null" ]]; then
      echo "$default"
    else
      echo "$val"
    fi
  }

  # --- Auto-detectar valores desde Terraform ---
  local gitea_registry
  gitea_registry=$(tf_output gitea_registry "${GITEA_REGISTRY:-${VPS_IP}:3000/${PROJECT_NAME}}")

  local k3s_api_server
  k3s_api_server=$(tf_output k3s_cluster_endpoint "https://${VPS_IP}:6443")

  local k3s_cluster_name
  k3s_cluster_name=$(tf_output k3s_cluster_name "k3s-${PROJECT_NAME}-dev")

  local aws_region="${AWS_REGION:-us-east-1}"

  # --- Overrides para dev (K3s nativo en VPS) ---
  local registry_insecure="true"   # Gitea HTTP (sin TLS en dev)
  local smoke_use_incluster="true"
  if [[ "$env_name" == "dev" ]]; then
    k3s_api_server="https://${VPS_IP}:6443"
    k3s_cluster_name="k3s-${PROJECT_NAME}-dev"
  fi

  local jenkins_url
  jenkins_url=$(tf_output jenkins_url "http://${VPS_IP}:8080")

  local jenkins_tunnel
  jenkins_tunnel=$(tf_output jenkins_tunnel "${VPS_IP}:50000")

  # Shared library repo — usa Gitea en VPS en dev
  local shared_library_repo="${SHARED_LIBRARY_REPO:-}"
  if [[ -z "$shared_library_repo" ]]; then
    if [[ "$env_name" == "dev" ]]; then
      shared_library_repo="http://${VPS_IP}:3000/${PROJECT_NAME}/jenkins-shared-library.git"
    fi
  fi

  local sonar_url="${SONAR_URL:-}"
  local sonar_token="${SONAR_TOKEN:-}"
  local slack_team="${SLACK_TEAM:-}"
  local slack_token="${SLACK_TOKEN:-}"
  local gitops_git_username="${GITOPS_GIT_USERNAME:-}"
  local gitops_git_token="${GITOPS_GIT_TOKEN:-}"

  if [[ "$env_name" == "dev" ]]; then
    gitops_git_username="${gitops_git_username:-gitea-admin}"
    gitops_git_token="${gitops_git_token:-gitea-admin}"
    # SonarQube se configura en base-infrastructure-builder.sh, persiste en .sonar-env.
    if [[ -f "$tf_dir/.sonar-env" ]]; then
      [[ -z "$sonar_url" ]]   && sonar_url="$(grep -E '^SONAR_URL='   "$tf_dir/.sonar-env" | cut -d= -f2- || true)"
      [[ -z "$sonar_token" ]] && sonar_token="$(grep -E '^SONAR_TOKEN=' "$tf_dir/.sonar-env" | cut -d= -f2- || true)"
    fi
  fi

  # --- Generar .env.jenkins ---
  log "Generando $env_file ..."
  cat > "$env_file" <<EOF
# Variables de entorno para el controller Jenkins (JCasC)
# Generado por setup-cicd-pipeline.sh — Sección 3
# Ambiente: $env_name

# Infraestructura del cluster / registry
GITEA_REGISTRY=$gitea_registry
K3S_API_SERVER=$k3s_api_server
K3S_CLUSTER_NAME=$k3s_cluster_name
AWS_REGION=$aws_region

# dev (K3s): registry Gitea HTTP (inseguro) y smoke tests in-cluster.
REGISTRY_INSECURE=$registry_insecure
SMOKE_USE_INCLUSTER=$smoke_use_incluster

# Jenkins networking (controller ↔ agentes en K3s)
JENKINS_URL=$jenkins_url
JENKINS_TUNNEL=$jenkins_tunnel

# Shared Library (Gitea en VPS)
SHARED_LIBRARY_REPO=$shared_library_repo

# SonarQube (VPS nativo)
SONAR_URL=$sonar_url
SONAR_TOKEN=$sonar_token

# Slack
SLACK_TEAM=$slack_team
SLACK_TOKEN=$slack_token

# GitOps (bumpImageTag push a Gitea)
GITOPS_GIT_USERNAME=$gitops_git_username
GITOPS_GIT_TOKEN=$gitops_git_token
EOF

  # --- Verificar variables pendientes ---
  [[ -z "$shared_library_repo" ]] && missing+=("SHARED_LIBRARY_REPO")
  [[ -z "$sonar_url" ]]          && missing+=("SONAR_URL")
  [[ -z "$sonar_token" ]]        && missing+=("SONAR_TOKEN")
  [[ "$env_name" != "dev" ]] && {
    [[ -z "$slack_team" ]]  && missing+=("SLACK_TEAM")
    [[ -z "$slack_token" ]] && missing+=("SLACK_TOKEN")
  }
  [[ -z "$gitops_git_username" ]] && missing+=("GITOPS_GIT_USERNAME")
  [[ -z "$gitops_git_token" ]]   && missing+=("GITOPS_GIT_TOKEN")

  if [[ ${#missing[@]} -gt 0 ]]; then
    log "Variables pendientes de configuración manual:"
    for var in "${missing[@]}"; do echo "  - $var"; done
    echo ""
    echo "  Edita $env_file y completa los valores faltantes."
  fi

  # --- Verificar Jenkins en VPS (servicio systemd) ---
  if [[ "$env_name" == "dev" ]]; then
    echo ""
    log "Verificando Jenkins en VPS ($VPS_IP:8080)..."
    if ssh_vps "systemctl is-active --quiet jenkins" 2>/dev/null; then
      log_ok "Jenkins activo en VPS."
    else
      log "Iniciando Jenkins en VPS..."
      ssh_vps "sudo systemctl start jenkins"
    fi

    # Copiar .env.jenkins al VPS y recargar Jenkins si es posible
    log "Copiando .env.jenkins al VPS..."
    scp -i "$VPS_SSH_KEY" -o StrictHostKeyChecking=no \
      "$env_file" "${VPS_USER}@${VPS_IP}:/tmp/.env.jenkins" 2>/dev/null || true

    log "Esperando a que Jenkins responda (puede tardar ~60 s)..."
    local jenkins_ready=0
    for _ in $(seq 1 40); do
      if curl -sf -o /dev/null "http://${VPS_IP}:8080/login" 2>/dev/null; then
        jenkins_ready=1
        break
      fi
      sleep 3
    done
    if [[ "$jenkins_ready" -eq 1 ]]; then
      log_ok "Jenkins respondiendo en http://${VPS_IP}:8080."
    else
      log "Jenkins aún no responde. SSH al VPS: sudo systemctl status jenkins"
    fi
  fi

  log_ok "Sección 3 completada — .env.jenkins generado en $env_file"
}

# ---------------------------------------------------------------------------
# Sección 4 — Crear los jobs de pipeline en Jenkins
# ---------------------------------------------------------------------------
section_4_crear_jobs_jenkins() {
  log "=== Sección 4 — Crear jobs de pipeline en Jenkins ==="

  local env_name="${DEPLOY_ENV:-dev}"
  local jobs_script="$PROJECT_ROOT/jenkins-shared-library/bootstrap/create-jobs.groovy"
  local jenkins_url="${JENKINS_URL:-http://${VPS_IP}:8080}"
  local jenkins_user="${JENKINS_USER:-admin}"
  local jenkins_token="${JENKINS_TOKEN:-}"

  # Determinar URL base de los repos Git según ambiente
  local git_base
  if [[ "$env_name" == "dev" ]]; then
    git_base="http://gitea:3000/${PROJECT_NAME}"
  else
    git_base="${GIT_BASE_URL:-https://github.com/${PROJECT_NAME}}"
  fi

  # --- Generar script Groovy para Jenkins Script Console ---
  log "Generando script de creación de jobs: $jobs_script"

  # Cabecera del script Groovy (heredoc quoted: $ de Groovy no se interpolan)
  cat > "$jobs_script" <<'GROOVY_HEADER'
import jenkins.model.Jenkins
import jenkins.branch.BranchSource
import jenkins.plugins.git.GitSCMSource
import jenkins.plugins.git.traits.*
import org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject

def jenkins = Jenkins.getInstanceOrNull()
if (jenkins == null) {
  println "ERROR: No se pudo obtener la instancia de Jenkins."
  return
}

// Lista de jobs a crear: [nombre, repo-url-relativo, es-frontend]
def jobs = [
GROOVY_HEADER

  # Inyectar jobs dinámicamente desde --services y --frontend
  IFS=',' read -ra _svc_list <<< "$SERVICES"
  for _svc in "${_svc_list[@]}"; do
    _svc="${_svc// /}"
    [[ -z "$_svc" ]] && continue
    printf "  ['%s', '%s', false],\n" "$_svc" "$_svc" >> "$jobs_script"
  done
  if [[ -n "$FRONTEND_NAME" ]]; then
    printf "  ['%s', '%s', true ],\n" "$FRONTEND_NAME" "$FRONTEND_NAME" >> "$jobs_script"
  fi

  # Resto del script Groovy
  cat >> "$jobs_script" <<GROOVY_FOOTER
]

def gitBase = '${git_base}'

GROOVY_FOOTER

  cat >> "$jobs_script" <<'GROOVY_BODY'
jobs.each { jobName, repoName, isFrontend ->
  def fullName = jobName
  def existing = jenkins.getItemByFullName(fullName)
  if (existing != null) {
    println "Job '${fullName}' ya existe. Se omite."
    return
  }

  def project = jenkins.createProject(WorkflowMultiBranchProject, fullName)
  project.displayName = jobName

  // Branch source: repositorio Git
  def repoUrl = "${gitBase}/${repoName}.git"
  def scmSource = new GitSCMSource(null, repoUrl, '', '*', '', true)
  scmSource.traits = [
    new BranchDiscoveryTrait(),
    new OriginPullRequestDiscoveryTrait(1), // Merged PRs
    new TagDiscoveryTrait()
  ]

  project.sourcesList.clear()
  project.sourcesList.add(new BranchSource(scmSource))

  // Orphaned item strategy: descartar ramas viejas tras 7 días
  project.orphanedItemStrategy = new com.cloudbees.hudson.plugins.folder.computed.DefaultOrphanedItemStrategy(
    true, '7', ''
  )

  // Trigger de webhook (plugin multibranch-scan-webhook-trigger): un POST de Gitea a
  // /multibranch-webhook-trigger/invoke?token=<jobName> dispara el escaneo del
  // multibranch. Vía reflection para no romper el script si el plugin no está.
  try {
    def triggerClass = Class.forName('com.igalg.jenkins.plugins.mswt.trigger.ComputedFolderWebHookTrigger')
    project.addTrigger(triggerClass.getConstructor(String.class).newInstance(fullName))
  } catch (Throwable t) {
    println "WARN: no se pudo agregar el webhook trigger a ${fullName}: ${t}"
  }

  project.save()
  println "Job creado: ${fullName}"
}

println "Listo. ${jobs.size()} jobs procesados."
GROOVY_BODY

  log "Script Groovy generado: $jobs_script"

  # --- Aplicar los jobs en el controller ---
  local script_content
  script_content=$(cat "$jobs_script")

  if [[ -n "$jenkins_token" ]]; then
    # Con API token (override manual o staging/prod): auth básica, sin crumb.
    log "Aplicando jobs vía REST API con token ($jenkins_url)..."
    local http_code
    http_code=$(curl -s -o /tmp/jenkins-job-result.txt -w "%{http_code}" \
      -X POST "$jenkins_url/scriptText" \
      --user "$jenkins_user:$jenkins_token" \
      --data-urlencode "script=$script_content" 2>&1 || true)
    if [[ "$http_code" == "200" ]]; then
      log_ok "Jobs creados vía API:"; cat /tmp/jenkins-job-result.txt
    else
      log_err "La API de Jenkins respondió HTTP $http_code — aplicá el script manualmente (Script Console): $jobs_script"
    fi
  elif [[ "$env_name" == "dev" ]]; then
    # dev: el controller corre sin security realm (anónimo = admin). Crumb + cookie.
    log "Aplicando jobs en el controller dev vía /scriptText..."
    local ready=0
    for _ in $(seq 1 40); do
      if curl -sf -o /dev/null "$jenkins_url/login" 2>/dev/null; then ready=1; break; fi
      sleep 3
    done
    if [[ "$ready" -eq 0 ]]; then
      log_err "Jenkins no respondió en $jenkins_url — omito la creación de jobs. Revisá: docker logs jenkins-controller"
    else
      local cookie_jar="/tmp/jenkins-cookies-$$.txt"
      local crumb
      crumb=$(curl -s -c "$cookie_jar" "$jenkins_url/crumbIssuer/api/json" 2>/dev/null \
        | grep -o '"crumb":"[^"]*"' | cut -d'"' -f4 || true)
      local -a crumb_args=()
      [[ -n "$crumb" ]] && crumb_args=(-H "Jenkins-Crumb: $crumb")
      local http_code
      http_code=$(curl -s -o /tmp/jenkins-job-result.txt -w "%{http_code}" \
        -b "$cookie_jar" "${crumb_args[@]}" \
        -X POST "$jenkins_url/scriptText" \
        --data-urlencode "script=$script_content" 2>&1 || true)
      rm -f "$cookie_jar"
      if [[ "$http_code" == "200" ]]; then
        log_ok "Jobs creados en Jenkins:"; cat /tmp/jenkins-job-result.txt
      else
        log_err "Jenkins respondió HTTP $http_code al crear jobs. Salida:"
        cat /tmp/jenkins-job-result.txt 2>/dev/null || true
      fi
    fi
  else
    log "JENKINS_TOKEN no definido (staging/prod). Aplicá el script manualmente:"
    echo "  export JENKINS_URL=...  JENKINS_USER=admin  JENKINS_TOKEN=<token>"
    echo "  o Manage Jenkins → Script Console → pegar: $jobs_script"
  fi

  # --- Webhooks de Gitea → Jenkins (dev) ---
  # Cada repo de la org recibe un webhook push+PR que pega al endpoint del plugin
  # multibranch-scan-webhook-trigger (?token=<repo> == nombre del job multibranch).
  # Gitea (floci-net) resuelve el controller por su nombre de contenedor.
  if [[ "$env_name" == "dev" ]]; then
    echo ""
    log "Configurando webhooks en Gitea (push + pull_request → Jenkins)..."
    local gitea_api="http://${VPS_IP}:3000/api/v1"
    local gitea_auth="gitea-admin:gitea-admin"
    local jenkins_internal="http://${VPS_IP}:8080"
    local org_repos
    org_repos=$(curl -s -u "$gitea_auth" "$gitea_api/orgs/${PROJECT_NAME}/repos?limit=100" 2>/dev/null \
      | grep -o '"name":"[^"]*"' | cut -d'"' -f4 || true)
    if [[ -z "$org_repos" ]]; then
      log_err "No se pudieron listar repos de la org '${PROJECT_NAME}' en Gitea — omito webhooks."
    else
      local repo created=0 skipped=0
      while IFS= read -r repo; do
        [[ -z "$repo" ]] && continue
        [[ "$repo" == "jenkins-shared-library" ]] && continue   # no es un job multibranch
        local hook_url="${jenkins_internal}/multibranch-webhook-trigger/invoke?token=${repo}"
        local existing
        existing=$(curl -s -u "$gitea_auth" "$gitea_api/repos/${PROJECT_NAME}/${repo}/hooks" 2>/dev/null \
          | grep -c "invoke?token=${repo}" || true)
        if [[ "${existing:-0}" -gt 0 ]]; then
          skipped=$((skipped + 1)); continue
        fi
        local code
        code=$(curl -s -o /dev/null -w "%{http_code}" -u "$gitea_auth" -X POST \
          "$gitea_api/repos/${PROJECT_NAME}/${repo}/hooks" \
          -H "Content-Type: application/json" \
          -d "{\"type\":\"gitea\",\"active\":true,\"events\":[\"push\",\"pull_request\"],\"config\":{\"url\":\"${hook_url}\",\"content_type\":\"json\"}}" 2>/dev/null || echo "000")
        case "$code" in
          200|201) log_ok "  $repo → webhook creado."; created=$((created + 1)) ;;
          *)        log_err "  $repo → Gitea devolvió HTTP $code al crear el webhook." ;;
        esac
      done <<< "$org_repos"
      log_ok "Webhooks Gitea: $created creado(s), $skipped ya existente(s)."
    fi
  fi

  log_ok "Sección 4 completada — jobs y webhooks procesados."
}

# ---------------------------------------------------------------------------
# Sección 5 — Bootstrap de ArgoCD (ApplicationSet por servicio)
# ---------------------------------------------------------------------------
section_5_bootstrap_argocd() {
  log "=== Sección 5 — Bootstrap de ArgoCD ==="

  local env_name="${DEPLOY_ENV:-dev}"
  local bootstrap_dir="$PROJECT_ROOT/terraform/backend/environments/$env_name/argocd-bootstrap"

  # dev (K3s nativo en VPS): ArgoCD se instaló vía Helm (vps-setup.sh k3s).
  # Se opera con el kubeconfig descargado desde el VPS.
  if [[ "$env_name" == "dev" ]]; then
    local kubeconfig="$PROJECT_ROOT/terraform/backend/environments/dev/.kube/config-k3s"
    if [[ ! -f "$kubeconfig" ]]; then
      log_err "Kubeconfig de K3s no encontrado: $kubeconfig. Ejecutá base-infrastructure-builder.sh con --vps-ip."
      exit 1
    fi
    export KUBECONFIG="$kubeconfig"
    log "Usando cluster K3s nativo en VPS (kubeconfig: $kubeconfig)."
  fi

  # Validar prerequisitos
  if ! command -v kubectl &>/dev/null; then
    log_err "kubectl no está instalado."
    exit 1
  fi
  if ! command -v argocd &>/dev/null; then
    log "argocd CLI no instalada — la verificación se hará con kubectl."
  fi
  if [[ ! -d "$bootstrap_dir" ]]; then
    log_err "Directorio de bootstrap no encontrado: $bootstrap_dir"
    log_err "Asegurate de que el módulo Terraform 'argocd' esté incluido en el ambiente '$env_name'."
    exit 1
  fi

  # Verificar que ArgoCD esté corriendo en el cluster
  log "Verificando que ArgoCD esté instalado en el cluster..."
  if ! kubectl get namespace argocd &>/dev/null; then
    log_err "Namespace 'argocd' no encontrado. Instalá ArgoCD en el cluster primero (módulo Terraform 'argocd')."
    exit 1
  fi

  # 1. Aplicar AppProject
  if [[ -f "$bootstrap_dir/appproject.yaml" ]]; then
    log "Aplicando AppProject..."
    kubectl apply -f "$bootstrap_dir/appproject.yaml"
  else
    log "appproject.yaml no encontrado, omitiendo."
  fi

  # 2. Aplicar credenciales de repositorio (si existe el Secret)
  local creds_file="$bootstrap_dir/repo-credentials.example.yaml"
  if [[ -f "$creds_file" ]]; then
    log "Aplicando credenciales de repositorio ArgoCD..."
    kubectl apply -f "$creds_file"
  else
    log "repo-credentials.example.yaml no encontrado. Creá las credenciales manualmente."
    echo "  kubectl create secret generic repo-creds-gitea-${PROJECT_NAME} \\"
    echo "    --namespace argocd \\"
    echo "    --from-literal=type=git \\"
    echo "    --from-literal=url=http://gitea:3000/${PROJECT_NAME} \\"
    echo "    --from-literal=username=gitea-admin \\"
    echo "    --from-literal=password=gitea-admin"
  fi

  # 3. Aplicar ApplicationSet
  if [[ -f "$bootstrap_dir/applicationset.yaml" ]]; then
    log "Aplicando ApplicationSet para ambiente '$env_name'..."
    kubectl apply -f "$bootstrap_dir/applicationset.yaml"
  else
    log_err "applicationset.yaml no encontrado en $bootstrap_dir"
    exit 1
  fi

  # 4. Verificación
  log "Verificando Applications de ArgoCD..."
  sleep 3

  if command -v argocd &>/dev/null; then
    log "Apps registradas en ArgoCD:"
    argocd app list 2>/dev/null || log "argocd CLI no pudo conectar. Verificá con: kubectl get applications -n argocd"
  fi

  log "Apps vía kubectl:"
  kubectl get applications -n argocd 2>/dev/null || log "No se encontraron Applications (posiblemente el ApplicationSet aún no las generó)."

  # Política de sync según ambiente
  echo ""
  log "Política de sync para '$env_name':"
  if [[ "$env_name" == "prod" ]]; then
    echo "  → Sync MANUAL desde la UI de ArgoCD (gate de release)."
  else
    echo "  → Auto-sync: automated (prune + selfHeal)."
  fi

  log_ok "Sección 5 completada — ArgoCD bootstrap aplicado."
}

# ---------------------------------------------------------------------------
# Sección 6 — Verificación del pipeline completo
# ---------------------------------------------------------------------------
section_6_verificar_pipeline() {
  log "=== Sección 6 — Verificación del pipeline completo ==="

  local env_name="${DEPLOY_ENV:-dev}"
  local kubeconfig="$PROJECT_ROOT/terraform/backend/environments/dev/.kube/config-k3d"
  local env_file="$PROJECT_ROOT/jenkins-shared-library/docker/.env.jenkins"
  local checks_ok=0
  local checks_fail=0
  local checks_warn=0

  chk_ok()   { echo "  [OK]   $*"; checks_ok=$((checks_ok + 1)); }
  chk_fail() { echo "  [FAIL] $*"; checks_fail=$((checks_fail + 1)); }
  chk_warn() { echo "  [WARN] $*"; checks_warn=$((checks_warn + 1)); }

  # --- 1. Shared Library ---
  echo ""
  log "--- 1. Shared Library ---"
  local var_count
  var_count=$(find "$PROJECT_ROOT/jenkins-shared-library/vars" -name "*.groovy" 2>/dev/null | wc -l || echo 0)
  if [[ "$var_count" -ge 10 ]]; then
    chk_ok "vars/ contiene $var_count steps Groovy"
  else
    chk_fail "vars/ incompleto ($var_count steps, se esperan ≥ 10)"
  fi

  local gitea_http
  # El repo se crea privado; sin credenciales Gitea responde 404 al anónimo.
  gitea_http=$(curl -s -o /dev/null -w "%{http_code}" -u "gitea-admin:gitea-admin" \
    "http://${VPS_IP}:3000/api/v1/repos/${PROJECT_NAME}/jenkins-shared-library" 2>/dev/null || echo "000")
  if [[ "$gitea_http" == "200" ]]; then
    chk_ok "Repositorio jenkins-shared-library accesible en Gitea (HTTP 200)"
  else
    chk_warn "Gitea devolvió HTTP $gitea_http para jenkins-shared-library — ¿git push pendiente?"
    echo "         → cd jenkins-shared-library && git push -u origin main"
  fi

  # --- 2. Jenkins controller (systemd en VPS) ---
  echo ""
  log "--- 2. Jenkins controller ---"
  if ssh_vps "systemctl is-active --quiet jenkins" 2>/dev/null; then
    chk_ok "jenkins.service activo en VPS ($VPS_IP)"
    local jenkins_http
    jenkins_http=$(curl -s -o /dev/null -w "%{http_code}" \
      "http://${VPS_IP}:8080/login" 2>/dev/null || echo "000")
    if [[ "$jenkins_http" == "200" ]]; then
      chk_ok "Jenkins UI responde en http://${VPS_IP}:8080 (HTTP 200)"
    else
      chk_warn "Jenkins UI en http://${VPS_IP}:8080 devolvió HTTP $jenkins_http (iniciando aún?)"
    fi
  else
    chk_warn "jenkins.service no está activo en VPS — iniciarlo con:"
    echo "         ssh ${VPS_USER}@${VPS_IP} sudo systemctl start jenkins"
  fi

  # --- 3b. Jobs Jenkins + webhooks Gitea (dev) ---
  if [[ "$env_name" == "dev" ]]; then
    echo ""
    log "--- 3b. Jobs Jenkins + webhooks Gitea ---"
    local job_count
    job_count=$(curl -s "http://${VPS_IP}:8080/api/json?tree=jobs[name]" 2>/dev/null \
      | grep -c '"name"' || true)
    if [[ "${job_count:-0}" -gt 0 ]]; then
      chk_ok "$job_count job(s) registrados en Jenkins"
    else
      chk_warn "No se detectaron jobs en Jenkins (¿controller iniciando o jobs no aplicados?)"
    fi
    local hooked=0 repo
    for repo in $(curl -s -u gitea-admin:gitea-admin \
        "http://${VPS_IP}:3000/api/v1/orgs/${PROJECT_NAME}/repos?limit=100" 2>/dev/null \
        | grep -o '"name":"[^"]*"' | cut -d'"' -f4 || true); do
      [[ "$repo" == "jenkins-shared-library" ]] && continue
      local n
      n=$(curl -s -u gitea-admin:gitea-admin \
        "http://${VPS_IP}:3000/api/v1/repos/${PROJECT_NAME}/${repo}/hooks" 2>/dev/null \
        | grep -c "multibranch-webhook-trigger" || true)
      [[ "${n:-0}" -gt 0 ]] && hooked=$((hooked + 1))
    done
    if [[ "$hooked" -gt 0 ]]; then
      chk_ok "$hooked repo(s) con webhook → Jenkins en Gitea"
    else
      chk_warn "Ningún repo con webhook a Jenkins en Gitea"
    fi
  fi

  # --- 4. K3d — Namespace y ServiceAccount ---
  echo ""
  log "--- 4. K3d — Namespace y ServiceAccount del agente ---"
  if [[ -f "$kubeconfig" ]]; then
    if kubectl --kubeconfig "$kubeconfig" get namespace jenkins &>/dev/null; then
      chk_ok "Namespace 'jenkins' existe en K3d"
    else
      chk_fail "Namespace 'jenkins' no encontrado en K3d"
    fi
    if kubectl --kubeconfig "$kubeconfig" get serviceaccount jenkins-agent -n jenkins &>/dev/null; then
      chk_ok "ServiceAccount 'jenkins-agent' existe en namespace 'jenkins'"
    else
      chk_fail "ServiceAccount 'jenkins-agent' no encontrada en namespace 'jenkins'"
    fi
    if kubectl --kubeconfig "$kubeconfig" get namespace dev &>/dev/null; then
      chk_ok "Namespace 'dev' existe en K3d (requerido por smoke tests)"
    else
      chk_warn "Namespace 'dev' no existe — smoke tests pueden fallar"
    fi
  else
    chk_fail "Kubeconfig K3d no encontrado: $kubeconfig"
  fi

  # --- 5. ArgoCD — Applications ---
  echo ""
  log "--- 5. ArgoCD — Applications registradas ---"
  if [[ -f "$kubeconfig" ]]; then
    local app_count
    app_count=$(kubectl --kubeconfig "$kubeconfig" get applications -n argocd \
      --no-headers 2>/dev/null | wc -l || echo 0)
    if [[ "$app_count" -ge "$EXPECTED_JOB_COUNT" ]]; then
      chk_ok "$app_count Applications registradas en ArgoCD (≥ ${EXPECTED_JOB_COUNT} esperadas)"
    else
      chk_fail "Se esperan ≥ ${EXPECTED_JOB_COUNT} Applications, se encontraron $app_count"
    fi

    local synced_count
    synced_count=$(kubectl --kubeconfig "$kubeconfig" get applications -n argocd \
      --no-headers 2>/dev/null | grep -c "Synced")
    synced_count=${synced_count//[^0-9]/}
    [[ -z "$synced_count" ]] && synced_count=0
    if [[ "$synced_count" -gt 0 ]]; then
      chk_ok "$synced_count Applications en estado Synced"
    else
      chk_warn "Ninguna Application en Synced — esperado hasta que los repos de servicio tengan charts Helm"
    fi
  else
    chk_warn "Kubeconfig K3d no disponible — no se puede verificar ArgoCD"
  fi

  # --- 6. Variables de entorno ---
  echo ""
  log "--- 6. Variables de entorno (.env.jenkins) ---"
  if [[ -f "$env_file" ]]; then
    # Slack es opcional en dev (notify hace fallback a echo); requerido en staging/prod.
    local required_vars=(SONAR_URL SONAR_TOKEN GITOPS_GIT_USERNAME GITOPS_GIT_TOKEN SHARED_LIBRARY_REPO)
    [[ "$env_name" != "dev" ]] && required_vars+=(SLACK_TEAM SLACK_TOKEN)
    local missing_vars=()
    for var in "${required_vars[@]}"; do
      local val
      val=$(grep -E "^${var}=.+" "$env_file" 2>/dev/null | cut -d= -f2- || true)
      [[ -z "$val" ]] && missing_vars+=("$var")
    done
    if [[ ${#missing_vars[@]} -eq 0 ]]; then
      chk_ok "Todas las variables requeridas están definidas en .env.jenkins"
    else
      for var in "${missing_vars[@]}"; do
        chk_warn "Variable pendiente: $var"
      done
      echo "         → Editá: $env_file"
    fi
  else
    chk_fail ".env.jenkins no encontrado: $env_file"
  fi

  # --- Resumen y próximos pasos ---
  echo ""
  log "--- Resumen ---"
  printf "  OK:   %d   WARN: %d   FAIL: %d\n" "$checks_ok" "$checks_warn" "$checks_fail"
  echo ""
  log "Criterios de aceptación pendientes (del documento DEV-02b-cicd):"
  if [[ "$env_name" == "dev" ]]; then
    echo "  ✓  git push de la shared library a Gitea — automático (jenkins-shared-library-builder.sh)"
    echo "  ✓  Variables .env.jenkins en dev — auto: SONAR_* (contenedor), GITOPS_* (gitea-admin); SLACK_* opcional"
    echo "  ✓  Controller Jenkins levantado automáticamente (docker run — Sección 3)"
    echo "  ✓  Jobs multibranch creados automáticamente en Jenkins (Sección 4)"
    echo "  ✓  Webhooks Gitea (push + PR) creados automáticamente (Sección 4)"
  else
    echo "  □  git push de la shared library a Gitea"
    echo "       cd jenkins-shared-library && git push -u origin main"
    echo "  □  Completar variables en .env.jenkins (SONAR_*, SLACK_*, GITOPS_*, VERCEL_*)"
    echo "  □  Levantar el controller Jenkins (en staging/prod lo gestiona Terraform)"
    echo "  □  Aplicar create-jobs.groovy en Manage Jenkins → Script Console"
    echo "  □  Configurar webhooks en el SCM (Push + PR) apuntando a Jenkins"
  fi
  echo "  □  Commit trivial en seguridad-service → verificar pipeline end-to-end"
  echo "  □  Application 'seguridad-service-dev' en ArgoCD queda Synced"
  echo ""
  if [[ "$checks_fail" -gt 0 ]]; then
    log_err "Sección 6: $checks_fail check(s) fallaron — revisar los items [FAIL] anteriores."
  else
    log_ok "Sección 6 completada — $checks_ok checks OK, $checks_warn advertencias."
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  log "Iniciando setup-cicd-pipeline.sh desde: $PROJECT_ROOT"

  section_0_generar_shared_library
  section_1_construir_imagen_controller
  section_2_bootstrap_cluster
  section_3_variables_credenciales
  section_4_crear_jobs_jenkins
  section_5_bootstrap_argocd
  section_6_verificar_pipeline

  log_ok "setup-cicd-pipeline.sh finalizado."
}

main "$@"
