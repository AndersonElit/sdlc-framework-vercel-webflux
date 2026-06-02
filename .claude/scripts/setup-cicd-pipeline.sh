#!/usr/bin/env bash
#
# setup-cicd-pipeline.sh
# Script unificado para configurar el pipeline CI/CD (Jenkins + ArgoCD GitOps).
# Cada sección es una función autocontenida. Se ejecutan en orden.
#
# Uso:
#   bash .claude/scripts/setup-cicd-pipeline.sh
#
set -euo pipefail

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
log_ok() { echo "[$(date '+%H:%M:%S')] OK  $*"; }
log_err() { echo "[$(date '+%H:%M:%S')] ERR $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ---------------------------------------------------------------------------
# Sección 0 — Generar la Shared Library
# ---------------------------------------------------------------------------
section_0_generar_shared_library() {
  log "=== Sección 0 — Generar la Shared Library ==="

  bash "$SCRIPT_DIR/jenkins-shared-library-builder.sh" -o "$PROJECT_ROOT/jenkins-shared-library"

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
  local image_name="flexicredit-jenkins"
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

  local bootstrap_yaml="$PROJECT_ROOT/jenkins-shared-library/bootstrap/jenkins-agent-rbac.yaml"
  local env_name="${DEPLOY_ENV:-dev}"

  # Validar prerequisitos
  if [[ ! -f "$bootstrap_yaml" ]]; then
    log_err "No se encontró $bootstrap_yaml. Ejecutá primero la Sección 0."
    exit 1
  fi
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

  # Obtener agent_role_arn desde output de Terraform
  log "Leyendo agent_role_arn desde Terraform ($env_name)..."
  local agent_role_arn
  agent_role_arn=$(cd "$tf_dir" && terraform output -raw jenkins_agent_role_arn 2>/dev/null || echo "")

  # En dev (floci) enable_compute=false → no hay IAM role ni EKS real.
  # El bootstrap de cluster solo aplica en staging/prod con EKS real.
  if [[ "$env_name" == "dev" || -z "$agent_role_arn" ]]; then
    log "Ambiente '$env_name': enable_compute=false o sin agent_role_arn."
    log "El bootstrap de cluster (namespace + ServiceAccount IRSA) solo aplica en staging/prod con EKS real."
    log "Se omite kubectl apply. Para validar el pipeline en dev, el foco es Jenkins + floci."
    log_ok "Sección 2 completada (omitida para ambiente dev)."
    return 0
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
  eks_cluster_name=$(tf_output eks_cluster_name "flexicredit-${env_name}")

  local aws_region="${AWS_REGION:-us-east-1}"

  local jenkins_url
  jenkins_url=$(tf_output jenkins_url "http://localhost:8080")

  local jenkins_tunnel
  jenkins_tunnel=$(tf_output jenkins_tunnel "localhost:50000")

  # Shared library repo — usa Gitea local en dev, remoto en staging/prod
  local shared_library_repo="${SHARED_LIBRARY_REPO:-}"
  if [[ -z "$shared_library_repo" ]]; then
    if [[ "$env_name" == "dev" ]]; then
      shared_library_repo="http://gitea:3000/flexicredit/jenkins-shared-library.git"
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

  # --- Generar .env.jenkins ---
  log "Generando $env_file ..."
  cat > "$env_file" <<EOF
# Variables de entorno para el controller Jenkins (JCasC)
# Generado por setup-cicd-pipeline.sh — Sección 3
# Ambiente: $env_name

# Infraestructura AWS
ECR_REGISTRY=$ecr_registry
EKS_API_SERVER=$eks_api_server
EKS_CLUSTER_NAME=$eks_cluster_name
AWS_REGION=$aws_region

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
  [[ -z "$slack_team" ]]         && missing+=("SLACK_TEAM")
  [[ -z "$slack_token" ]]        && missing+=("SLACK_TOKEN")
  [[ "$env_name" != "dev" ]] && {
    [[ -z "$vercel_token" ]]     && missing+=("VERCEL_TOKEN")
    [[ -z "$vercel_org_id" ]]    && missing+=("VERCEL_ORG_ID")
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

  # --- Mostrar comando docker run para ambiente dev ---
  if [[ "$env_name" == "dev" ]]; then
    echo ""
    log "Para ejecutar el controller Jenkins en dev:"
    echo ""
    echo "  docker run --rm --name jenkins-controller \\"
    echo "    --env-file jenkins-shared-library/docker/.env.jenkins \\"
    echo "    --network floci-net \\"
    echo "    -p 8080:8080 -p 50000:50000 \\"
    echo "    -v jenkins_home:/var/jenkins_home \\"
    echo "    $ecr_registry/flexicredit-jenkins:latest"
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
    git_base="http://gitea:3000/flexicredit"
  else
    git_base="${GIT_BASE_URL:-https://github.com/flexicredit}"
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
  ['flexicredit-web',        'flexicredit-web',        true ],
]

def gitBase = System.getenv('GIT_BASE_URL') ?: 'http://gitea:3000/flexicredit'

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

  project.save()
  println "Job creado: ${fullName}"
}

println "Listo. ${jobs.size()} jobs procesados."
GROOVY_EOF

  # --- Inyectar git_base real en el script ---
  # Reemplazar el fallback del script con el valor detectado
  sed -i "s|def gitBase = .*|def gitBase = '${git_base}'|" "$jobs_script"

  log "Script Groovy generado: $jobs_script"

  # --- Intentar aplicar vía REST API si hay token ---
  if [[ -n "$jenkins_token" ]]; then
    log "Aplicando jobs vía REST API ($jenkins_url)..."
    local script_content
    script_content=$(cat "$jobs_script")

    local http_code
    http_code=$(curl -s -o /tmp/jenkins-job-result.txt -w "%{http_code}" \
      -X POST "$jenkins_url/scriptText" \
      --user "$jenkins_user:$jenkins_token" \
      --data-urlencode "script=$script_content" 2>&1 || true)

    if [[ "$http_code" == "200" ]]; then
      log_ok "Jobs creados vía API. Respuesta:"
      cat /tmp/jenkins-job-result.txt
    else
      log "La API de Jenkins respondió HTTP $http_code (¿controller no disponible?)."
      log "Aplicá el script manualmente cuando Jenkins esté corriendo:"
    fi
  else
    log "JENKINS_TOKEN no definido. Para crear los jobs automáticamente, exportá:"
    echo "  export JENKINS_URL=http://localhost:8080"
    echo "  export JENKINS_USER=admin"
    echo "  export JENKINS_TOKEN=<token>"
    echo ""
    log "Alternativa manual: abrí Jenkins → Manage Jenkins → Script Console y ejecutá:"
  fi

  echo ""
  echo "  Script: $jobs_script"
  echo "  Ruta en Jenkins: Manage Jenkins → Script Console"

  log_ok "Sección 4 completada — Script de jobs generado."
}

# ---------------------------------------------------------------------------
# Sección 5 — Bootstrap de ArgoCD (ApplicationSet por servicio)
# ---------------------------------------------------------------------------
section_5_bootstrap_argocd() {
  log "=== Sección 5 — Bootstrap de ArgoCD ==="

  local env_name="${DEPLOY_ENV:-dev}"
  local bootstrap_dir="$PROJECT_ROOT/terraform/backend/environments/$env_name/argocd-bootstrap"

  # ArgoCD solo aplica en staging/prod con EKS real.
  # En dev (floci) no hay cluster EKS ni módulo argocd.
  if [[ "$env_name" == "dev" ]]; then
    log "Ambiente dev (floci): no hay cluster EKS ni ArgoCD."
    log "El bootstrap de ArgoCD solo aplica en staging/prod."
    log_ok "Sección 5 completada (omitida para ambiente dev)."
    return 0
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
    echo "  kubectl create secret generic repo-creds-gitea-flexicredit \\"
    echo "    --namespace argocd \\"
    echo "    --from-literal=type=git \\"
    echo "    --from-literal=url=http://gitea:3000/flexicredit \\"
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

  # TODO: pendiente de implementar
  log "Sección 6 — pendiente"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  log "Iniciando setup-cicd-pipeline.sh desde: $PROJECT_ROOT"

  # section_0_generar_shared_library
  # section_1_construir_imagen_controller
  # section_2_bootstrap_cluster
  # section_3_variables_credenciales
  # section_4_crear_jobs_jenkins
  section_5_bootstrap_argocd
  # section_6_verificar_pipeline

  log_ok "setup-cicd-pipeline.sh finalizado."
}

main "$@"
