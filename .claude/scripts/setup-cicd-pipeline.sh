#!/usr/bin/env bash
#
# setup-cicd-pipeline.sh
# Script unificado para configurar el pipeline CI/CD (Jenkins + ArgoCD GitOps).
# Cada sección es una función autocontenida. Se ejecutan en orden.
#
# Uso:
#   bash .claude/scripts/setup-cicd-pipeline.sh -P <proyecto>
#
#   -P, --project NOMBRE   Slug del proyecto (obligatorio). Nombra la imagen del
#                          controller (<proyecto>-jenkins), el cluster K3d/EKS,
#                          la organización Gitea y los recursos de ArgoCD.
#
set -euo pipefail

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
log_ok() { echo "[$(date '+%H:%M:%S')] OK  $*"; }
log_err() { echo "[$(date '+%H:%M:%S')] ERR $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PROJECT_NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -P|--project) PROJECT_NAME="${2:-}"; shift 2 ;;
    --project=*)  PROJECT_NAME="${1#*=}"; shift ;;
    -h|--help)    grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) log_err "Argumento desconocido: $1"; exit 1 ;;
  esac
done
if [[ -z "$PROJECT_NAME" ]]; then
  log_err "Falta el parámetro obligatorio -P/--project."
  exit 1
fi
ORG_SLUG="$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"

# ---------------------------------------------------------------------------
# Sección 0 — Generar la Shared Library
# ---------------------------------------------------------------------------
section_0_generar_shared_library() {
  log "=== Sección 0 — Generar la Shared Library ==="

  bash "$SCRIPT_DIR/jenkins-shared-library-builder.sh" -P "$PROJECT_NAME" -o "$PROJECT_ROOT/jenkins-shared-library"

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

  # dev (K3d): el controller Jenkins corre como contenedor local en floci-net,
  # directamente desde la imagen construida. No se publica en ningún registry
  # (K3d no necesita la imagen del controller; solo las de los microservicios).
  if [[ "$env_name" == "dev" ]]; then
    log "Construyendo imagen del controller: $image_name:$image_tag (dev, sin push)"
    docker build -t "$image_name:$image_tag" "$docker_dir"
    log_ok "Sección 1 completada — imagen local $image_name:$image_tag lista (corre en floci-net)."
    return 0
  fi

  # ECR registry: se toma de variable de entorno o se intenta leer de Terraform
  local ecr_registry="${ECR_REGISTRY:-}"
  if [[ -z "$ecr_registry" ]]; then
    # Intentar leer de output de Terraform (módulo ecr)
    local tf_dir="$PROJECT_ROOT/terraform/backend/environments/dev"
    if [[ -d "$tf_dir" ]]; then
      ecr_registry=$(cd "$tf_dir" && terraform output -raw ecr_registry 2>/dev/null || true)
    fi
  fi
  if [[ -z "$ecr_registry" ]]; then
    log_err "ECR_REGISTRY no definido. Exportalo o asegurate de que 'terraform output ecr_registry' esté disponible."
    log_err "  Ejemplo: export ECR_REGISTRY=000000000000.dkr.ecr.us-east-1.amazonaws.com"
    exit 1
  fi
  log "ECR registry: $ecr_registry"

  # Determinar si estamos en dev (floci) o staging/prod (AWS real)
  local aws_endpoint=""
  if [[ -n "${AWS_ENDPOINT_URL:-}" ]]; then
    aws_endpoint="$AWS_ENDPOINT_URL"
  elif curl -sf http://localhost:4566/_localstack/health &>/dev/null 2>&1; then
    aws_endpoint="http://localhost:4566"
    log "floci detectado en http://localhost:4566"
  fi

  local aws_region="${AWS_REGION:-us-east-1}"

  # 1. Build de la imagen del controller
  log "Construyendo imagen Docker: $image_name:$image_tag"
  docker build -t "$image_name:$image_tag" "$docker_dir"

  # 2. Crear repositorio ECR si no existe
  log "Verificando/creando repositorio ECR: $image_name"
  local ecr_args=(ecr describe-repositories --repository-names "$image_name" --region "$aws_region")
  if [[ -n "$aws_endpoint" ]]; then
    ecr_args=(--endpoint-url="$aws_endpoint" "${ecr_args[@]}")
  fi
  if ! aws "${ecr_args[@]}" &>/dev/null; then
    log "Repositorio no existe, creándolo..."
    local create_args=(ecr create-repository --repository-name "$image_name" --region "$aws_region")
    if [[ -n "$aws_endpoint" ]]; then
      create_args=(--endpoint-url="$aws_endpoint" "${create_args[@]}")
    fi
    aws "${create_args[@]}" >/dev/null
    log_ok "Repositorio ECR creado: $image_name"
  fi

  # 3. Login a ECR
  log "Autenticando en ECR..."
  if [[ -n "$aws_endpoint" ]]; then
    aws --endpoint-url="$aws_endpoint" ecr get-login-password --region "$aws_region" \
      | docker login --username AWS --password-stdin "$ecr_registry"
  else
    aws ecr get-login-password --region "$aws_region" \
      | docker login --username AWS --password-stdin "$ecr_registry"
  fi

  # 4. Tag y push
  local remote_image="${ecr_registry}/${image_name}:${image_tag}"
  log "Tageando y publicando: $remote_image"
  docker tag "$image_name:$image_tag" "$remote_image"
  docker push "$remote_image"

  # Verificación: en floci el ECR API no registra imágenes pusheadas vía Docker
  # registry (limitación del emulador), así que usamos 'docker pull'.
  # En AWS real usamos 'aws ecr describe-images'.
  log "Verificando imagen en ECR..."
  if [[ -n "$aws_endpoint" ]]; then
    # floci: verificar con docker pull
    if ! docker pull "$remote_image" &>/dev/null; then
      log_err "La imagen no se encuentra en ECR: $remote_image"
      exit 1
    fi
  else
    # AWS real: verificar con describe-images
    if ! aws ecr describe-images --repository-name "$image_name" --image-ids "imageTag=$image_tag" --region "$aws_region" --output text &>/dev/null; then
      log_err "La imagen no se encuentra en ECR: $image_name:$image_tag"
      exit 1
    fi
  fi

  log_ok "Sección 1 completada — Imagen publicada en ECR: $remote_image"
  echo "  Actualizá var.jenkins_image en el módulo Terraform 'jenkins' con:"
  echo "    jenkins_image = \"$remote_image\""
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

  # --- dev (K3d): cluster real, sin IRSA ---
  # Se aplica el RBAC del agente que genera base-infrastructure-builder.sh: namespace
  # jenkins + SA jenkins-agent + Role/RoleBinding para smoke tests en el namespace dev.
  if [[ "$env_name" == "dev" ]]; then
    local kubeconfig="$tf_dir/.kube/config-k3d"
    local dev_rbac="$tf_dir/argocd-bootstrap/jenkins-agent-rbac-dev.yaml"
    if [[ ! -f "$kubeconfig" ]]; then
      log_err "Kubeconfig de K3d no encontrado: $kubeconfig. Ejecutá primero base-infrastructure-builder.sh (floci-start)."
      exit 1
    fi
    if [[ ! -f "$dev_rbac" ]]; then
      log_err "No se encontró $dev_rbac. Regenerá la infra con base-infrastructure-builder.sh."
      exit 1
    fi
    log "Aplicando RBAC del agente al cluster K3d..."
    kubectl --kubeconfig "$kubeconfig" apply -f "$dev_rbac"
    if ! kubectl --kubeconfig "$kubeconfig" get serviceaccount jenkins-agent -n jenkins &>/dev/null; then
      log_err "ServiceAccount 'jenkins-agent' no se creó en namespace 'jenkins'."
      exit 1
    fi
    log_ok "Sección 2 completada — RBAC del agente aplicado en K3d (sin IRSA)."
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
  local ecr_registry
  ecr_registry=$(tf_output ecr_registry "${ECR_REGISTRY:-}")

  local eks_api_server
  eks_api_server=$(tf_output eks_cluster_endpoint "https://placeholder.eks.us-east-1.amazonaws.com")

  local eks_cluster_name
  eks_cluster_name=$(tf_output eks_cluster_name "${PROJECT_NAME}-${env_name}")

  local aws_region="${AWS_REGION:-us-east-1}"

  # --- Overrides para dev (K3d) ---
  # El API server es el load balancer de k3d en floci-net; el registry es inseguro
  # (HTTP) y el agente corre dentro del cluster (smoke tests sin 'aws eks').
  local registry_insecure="false"
  local smoke_use_incluster="false"
  if [[ "$env_name" == "dev" ]]; then
    eks_api_server="https://k3d-${PROJECT_NAME}-dev-serverlb:6443"
    eks_cluster_name="${PROJECT_NAME}-dev"
    registry_insecure="true"
    smoke_use_incluster="true"
  fi

  local jenkins_url
  jenkins_url=$(tf_output jenkins_url "http://localhost:8080")

  local jenkins_tunnel
  jenkins_tunnel=$(tf_output jenkins_tunnel "localhost:50000")

  # Shared library repo — usa Gitea local en dev, remoto en staging/prod
  local shared_library_repo="${SHARED_LIBRARY_REPO:-}"
  if [[ -z "$shared_library_repo" ]]; then
    if [[ "$env_name" == "dev" ]]; then
      shared_library_repo="http://gitea:3000/${PROJECT_NAME}/jenkins-shared-library.git"
    fi
  fi

  # Configuración externa (obligatoria; si no están definidas se registran como pendientes)
  local sonar_url="${SONAR_URL:-}"
  local sonar_token="${SONAR_TOKEN:-}"
  local slack_team="${SLACK_TEAM:-}"
  local slack_token="${SLACK_TOKEN:-}"
  local vercel_token="${VERCEL_TOKEN:-}"
  local vercel_org_id="${VERCEL_ORG_ID:-}"
  local vercel_project_id="${VERCEL_PROJECT_ID:-}"
  local gitops_git_username="${GITOPS_GIT_USERNAME:-}"
  local gitops_git_token="${GITOPS_GIT_TOKEN:-}"
  # En dev los repos GitOps viven en Gitea local: bumpImageTag pushea con las
  # mismas credenciales fijas del admin (gitea-admin/gitea-admin), igual que el
  # resto del script. No es una credencial "externa" que el usuario deba proveer.
  if [[ "$env_name" == "dev" ]]; then
    gitops_git_username="${gitops_git_username:-gitea-admin}"
    gitops_git_token="${gitops_git_token:-gitea-admin}"
    # SonarQube se aprovisiona en floci-start (base-infrastructure-builder.sh),
    # que persiste URL + token en .sonar-env. Los leemos para no pedirlos a mano.
    if [[ -f "$tf_dir/.sonar-env" ]]; then
      if [[ -z "$sonar_url" ]]; then
        sonar_url="$(grep -E '^SONAR_URL=' "$tf_dir/.sonar-env" | cut -d= -f2- || true)"
      fi
      if [[ -z "$sonar_token" ]]; then
        sonar_token="$(grep -E '^SONAR_TOKEN=' "$tf_dir/.sonar-env" | cut -d= -f2- || true)"
      fi
    fi
  fi

  # --- Generar .env.jenkins ---
  log "Generando $env_file ..."
  cat > "$env_file" <<EOF
# Variables de entorno para el controller Jenkins (JCasC)
# Generado por setup-cicd-pipeline.sh — Sección 3
# Ambiente: $env_name

# Infraestructura del cluster / registry
ECR_REGISTRY=$ecr_registry
EKS_API_SERVER=$eks_api_server
EKS_CLUSTER_NAME=$eks_cluster_name
AWS_REGION=$aws_region

# dev (K3d): registry inseguro (HTTP) y smoke tests in-cluster. false en EKS.
REGISTRY_INSECURE=$registry_insecure
SMOKE_USE_INCLUSTER=$smoke_use_incluster

# Jenkins networking (controller ↔ agentes)
JENKINS_URL=$jenkins_url
JENKINS_TUNNEL=$jenkins_tunnel

# Shared Library
SHARED_LIBRARY_REPO=$shared_library_repo

# SonarQube
SONAR_URL=$sonar_url
SONAR_TOKEN=$sonar_token

# Slack
SLACK_TEAM=$slack_team
SLACK_TOKEN=$slack_token

# Vercel (deploy frontend)
VERCEL_TOKEN=$vercel_token
VERCEL_ORG_ID=$vercel_org_id
VERCEL_PROJECT_ID=$vercel_project_id

# GitOps (bumpImageTag push)
GITOPS_GIT_USERNAME=$gitops_git_username
GITOPS_GIT_TOKEN=$gitops_git_token
EOF

  # --- Verificar variables pendientes ---
  [[ -z "$shared_library_repo" ]] && missing+=("SHARED_LIBRARY_REPO")
  [[ -z "$sonar_url" ]]          && missing+=("SONAR_URL")
  [[ -z "$sonar_token" ]]        && missing+=("SONAR_TOKEN")
  # Slack es opcional en dev (notify hace fallback a echo); obligatorio en staging/prod.
  [[ "$env_name" != "dev" ]] && {
    [[ -z "$slack_team" ]]        && missing+=("SLACK_TEAM")
    [[ -z "$slack_token" ]]       && missing+=("SLACK_TOKEN")
    [[ -z "$vercel_token" ]]      && missing+=("VERCEL_TOKEN")
    [[ -z "$vercel_org_id" ]]     && missing+=("VERCEL_ORG_ID")
    [[ -z "$vercel_project_id" ]] && missing+=("VERCEL_PROJECT_ID")
  }
  [[ -z "$gitops_git_username" ]] && missing+=("GITOPS_GIT_USERNAME")
  [[ -z "$gitops_git_token" ]]   && missing+=("GITOPS_GIT_TOKEN")

  if [[ ${#missing[@]} -gt 0 ]]; then
    log "Las siguientes variables requieren configuración manual:"
    for var in "${missing[@]}"; do
      echo "  - $var"
    done
    echo ""
    echo "  Editá $env_file y completá los valores faltantes."
  fi

  # --- Levantar el controller Jenkins en dev (docker run) ---
  # El controller corre en floci-net (alcanza gitea, k3d-serverlb, registry). El
  # kubeconfig interno de k3d se monta en /var/jenkins_home/.kube/config: el JCasC lo
  # lee para la credencial 'eks-kubeconfig' y el cloud Kubernetes lanza agentes en K3d.
  # Se usa la imagen LOCAL ${PROJECT_NAME}-jenkins:latest (la Sección 1 no la publica en dev).
  # En staging/prod el controller lo gestiona Terraform (módulo Jenkins en EKS), no acá.
  if [[ "$env_name" == "dev" ]]; then
    echo ""
    log "Levantando el controller Jenkins en dev (docker run)..."

    local jenkins_image="${PROJECT_NAME}-jenkins:latest"
    local kubeconfig_internal="$PROJECT_ROOT/terraform/backend/environments/dev/.kube/config-k3d-internal"

    if ! docker image inspect "$jenkins_image" &>/dev/null; then
      log_err "Imagen $jenkins_image no encontrada — corré la Sección 1 (build) primero. Omito el arranque."
    elif [[ ! -f "$kubeconfig_internal" ]]; then
      log_err "Kubeconfig interno de K3d no encontrado: $kubeconfig_internal"
      log_err "  Corré base-infrastructure-builder.sh (floci-start) primero. Omito el arranque."
    elif ! docker network inspect floci-net &>/dev/null; then
      log_err "Red floci-net no existe — corré floci-start primero. Omito el arranque."
    else
      # Idempotente: recrear el contenedor conserva el volumen jenkins_home.
      if docker ps -a --format '{{.Names}}' | grep -qx "jenkins-controller"; then
        log "Contenedor jenkins-controller ya existe — recreando (jenkins_home se conserva)..."
        docker rm -f jenkins-controller &>/dev/null || true
      fi
      if docker run -d --name jenkins-controller \
        --env-file "$env_file" \
        --network floci-net \
        -p 8080:8080 -p 50000:50000 \
        -v jenkins_home:/var/jenkins_home \
        -v "${kubeconfig_internal}:/var/jenkins_home/.kube/config:ro" \
        "$jenkins_image" >/dev/null; then
        log_ok "Controller Jenkins levantado en floci-net."
        log "Esperando a que Jenkins responda (puede tardar ~60s)..."
        local jenkins_ready=0
        for _ in $(seq 1 40); do
          if curl -sf -o /dev/null http://localhost:8080/login 2>/dev/null; then
            jenkins_ready=1
            break
          fi
          sleep 3
        done
        if [[ "$jenkins_ready" -eq 1 ]]; then
          log_ok "Jenkins respondiendo en http://localhost:8080."
        else
          log "Jenkins aún no responde (~2 min). Seguí el arranque con: docker logs -f jenkins-controller"
        fi
      else
        log_err "Falló el arranque del controller. Revisá: docker logs jenkins-controller"
      fi
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
  local jenkins_url="${JENKINS_URL:-http://localhost:8080}"
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
  cat > "$jobs_script" <<'GROOVY_EOF'
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
  ['seguridad-service',      'seguridad-service',      false],
  ['configuracion-service',  'configuracion-service',  false],
  ['clientes-service',       'clientes-service',       false],
  ['tasas-service',          'tasas-service',          false],
  ['originacion-service',    'originacion-service',    false],
  ['ciclovida-service',      'ciclovida-service',      false],
  ['auditoria-service',      'auditoria-service',      false],
  ['reportes-service',       'reportes-service',       false],
  ['__PROJECT_NAME__-web',   '__PROJECT_NAME__-web',   true ],
]

def gitBase = System.getenv('GIT_BASE_URL') ?: 'http://gitea:3000/__PROJECT_NAME__'

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
GROOVY_EOF

  # --- Inyectar git_base real y el nombre del proyecto en el script ---
  sed -i "s|def gitBase = .*|def gitBase = '${git_base}'|" "$jobs_script"
  sed -i "s|__PROJECT_NAME__|${PROJECT_NAME}|g" "$jobs_script"

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
    local gitea_api="http://localhost:3000/api/v1"
    local gitea_auth="gitea-admin:gitea-admin"
    local jenkins_internal="http://jenkins-controller:8080"
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

  # dev (K3d): ArgoCD se instala en el cluster K3d (módulo terraform 'argocd' en dev).
  # Se opera con el kubeconfig host de k3d. staging/prod usan el contexto kubectl actual.
  if [[ "$env_name" == "dev" ]]; then
    local kubeconfig="$PROJECT_ROOT/terraform/backend/environments/dev/.kube/config-k3d"
    if [[ ! -f "$kubeconfig" ]]; then
      log_err "Kubeconfig de K3d no encontrado: $kubeconfig. Ejecutá base-infrastructure-builder.sh (floci-start)."
      exit 1
    fi
    export KUBECONFIG="$kubeconfig"
    log "Usando cluster K3d (kubeconfig: $kubeconfig)."
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
    "http://localhost:3000/api/v1/repos/${PROJECT_NAME}/jenkins-shared-library" 2>/dev/null || echo "000")
  if [[ "$gitea_http" == "200" ]]; then
    chk_ok "Repositorio jenkins-shared-library accesible en Gitea (HTTP 200)"
  else
    chk_warn "Gitea devolvió HTTP $gitea_http para jenkins-shared-library — ¿git push pendiente?"
    echo "         → cd jenkins-shared-library && git push -u origin main"
  fi

  # --- 2. Imagen del controller ---
  echo ""
  log "--- 2. Imagen del controller ---"
  if docker image inspect "${PROJECT_NAME}-jenkins:latest" &>/dev/null; then
    chk_ok "Imagen Docker ${PROJECT_NAME}-jenkins:latest existe localmente"
  else
    chk_fail "Imagen Docker ${PROJECT_NAME}-jenkins:latest no encontrada"
  fi

  # --- 3. Jenkins controller corriendo ---
  echo ""
  log "--- 3. Jenkins controller ---"
  if docker ps --filter "name=jenkins-controller" --filter "status=running" \
       --format "{{.Names}}" 2>/dev/null | grep -q "jenkins-controller"; then
    chk_ok "Contenedor jenkins-controller está corriendo"
    local jenkins_http
    jenkins_http=$(curl -s -o /dev/null -w "%{http_code}" \
      "http://localhost:8080/login" 2>/dev/null || echo "000")
    if [[ "$jenkins_http" == "200" ]]; then
      chk_ok "Jenkins UI responde en http://localhost:8080 (HTTP 200)"
    else
      chk_warn "Jenkins UI en http://localhost:8080 devolvió HTTP $jenkins_http (iniciando aún?)"
    fi
  else
    chk_warn "Contenedor jenkins-controller no está corriendo — iniciarlo con:"
    echo "         docker run -d --name jenkins-controller \\"
    echo "           --env-file jenkins-shared-library/docker/.env.jenkins \\"
    echo "           --network floci-net -p 8080:8080 -p 50000:50000 \\"
    echo "           -v jenkins_home:/var/jenkins_home \\"
    echo "           -v \$(pwd)/terraform/backend/environments/dev/.kube/config-k3d-internal:/var/jenkins_home/.kube/config:ro \\"
    echo "           ${PROJECT_NAME}-jenkins:latest"
  fi

  # --- 3b. Jobs Jenkins + webhooks Gitea (dev) ---
  if [[ "$env_name" == "dev" ]]; then
    echo ""
    log "--- 3b. Jobs Jenkins + webhooks Gitea ---"
    local job_count
    job_count=$(curl -s "http://localhost:8080/api/json?tree=jobs[name]" 2>/dev/null \
      | grep -c '"name"' || true)
    if [[ "${job_count:-0}" -gt 0 ]]; then
      chk_ok "$job_count job(s) registrados en Jenkins"
    else
      chk_warn "No se detectaron jobs en Jenkins (¿controller iniciando o jobs no aplicados?)"
    fi
    local hooked=0 repo
    for repo in $(curl -s -u gitea-admin:gitea-admin \
        "http://localhost:3000/api/v1/orgs/${PROJECT_NAME}/repos?limit=100" 2>/dev/null \
        | grep -o '"name":"[^"]*"' | cut -d'"' -f4 || true); do
      [[ "$repo" == "jenkins-shared-library" ]] && continue
      local n
      n=$(curl -s -u gitea-admin:gitea-admin \
        "http://localhost:3000/api/v1/repos/${PROJECT_NAME}/${repo}/hooks" 2>/dev/null \
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
    if [[ "$app_count" -ge 8 ]]; then
      chk_ok "$app_count Applications registradas en ArgoCD (≥ 8 esperadas)"
    else
      chk_fail "Se esperan ≥ 8 Applications, se encontraron $app_count"
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
