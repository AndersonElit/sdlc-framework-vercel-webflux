#!/usr/bin/env bash

set -euo pipefail

log() { echo "[$(date '+%H:%M:%S')] $*"; }
log_ok() { echo "[$(date '+%H:%M:%S')] OK  $*"; }
log_err() { echo "[$(date '+%H:%M:%S')] ERR $*" >&2; }

log "Iniciando floci-start..."

log "Verificando dependencias..."
check_cmd() {
  if command -v "$1" &>/dev/null; then
    log_ok "$1 encontrado ($(command -v "$1"))."
  else
    log_err "$1 no está instalado. Abortando."
    exit 1
  fi
}
check_cmd docker
check_cmd terraform

log "Deteniendo contenedores activos..."
if docker ps -aq | grep -q .; then
  docker stop $(docker ps -aq) && log_ok "Contenedores detenidos."
else
  log "No hay contenedores activos."
fi

log "Eliminando contenedores..."
if docker ps -aq | grep -q .; then
  docker rm $(docker ps -aq) && log_ok "Contenedores eliminados."
else
  log "No hay contenedores para eliminar."
fi

log "Eliminando imágenes..."
if docker images -aq | grep -q .; then
  docker rmi $(docker images -aq) && log_ok "Imágenes eliminadas."
else
  log "No hay imágenes para eliminar."
fi

log "Levantando contenedor floci..."
docker run -d \
  --name floci \
  --network floci-net \
  -p 4566:4566 \
  -p 5000-5099:5000-5099 \
  -p 5101-6499:5101-6499 \
  -p 6501-8000:6501-8000 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --add-host=host.docker.internal:host-gateway \
  -e DOCKER_NETWORK=floci-net \
  floci/floci:latest

log_ok "Floci listo."

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
  "$TF_BACKEND/modules/vpc" \
  "$TF_BACKEND/modules/eks" \
  "$TF_BACKEND/modules/rds" \
  "$TF_BACKEND/environments/dev" \
  "$TF_BACKEND/environments/staging" \
  "$TF_BACKEND/environments/prod"

# ===========================================================================
# FRONTEND — provider Vercel
# ===========================================================================

# ---------------------------------------------------------------------------
# frontend/modules/vercel-project/
# ---------------------------------------------------------------------------
cat > "$TF_FRONTEND/modules/vercel-project/main.tf" << 'EOF'
resource "vercel_project" "this" {
  name      = var.project_name
  framework = var.framework

  git_repository {
    type = var.git_type
    repo = var.git_repo
  }
}

resource "vercel_project_environment_variable" "api_url" {
  project_id = vercel_project.this.id
  key        = "NEXT_PUBLIC_API_URL"
  value      = var.api_url
  target     = ["production", "preview", "development"]
}
EOF

cat > "$TF_FRONTEND/modules/vercel-project/variables.tf" << 'EOF'
variable "project_name" {
  description = "Nombre del proyecto en Vercel"
  type        = string
}

variable "framework" {
  description = "Framework del proyecto (nextjs, create-react-app, etc.)"
  type        = string
  default     = "nextjs"
}

variable "git_type" {
  description = "Proveedor Git: github | gitlab | bitbucket"
  type        = string
  default     = "github"
}

variable "git_repo" {
  description = "Repositorio Git (owner/repo)"
  type        = string
}

variable "api_url" {
  description = "URL del backend expuesta al frontend"
  type        = string
}
EOF

cat > "$TF_FRONTEND/modules/vercel-project/outputs.tf" << 'EOF'
output "project_id" {
  description = "ID del proyecto Vercel"
  value       = vercel_project.this.id
}

output "deployment_url" {
  description = "URL de despliegue del proyecto"
  value       = "https://${vercel_project.this.name}.vercel.app"
}
EOF

# ---------------------------------------------------------------------------
# frontend/environments/dev/
# ---------------------------------------------------------------------------
cat > "$TF_FRONTEND/environments/dev/providers.tf" << 'EOF'
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    vercel = {
      source  = "vercel/vercel"
      version = "~> 2.0"
    }
  }
}

provider "vercel" {
  api_token = var.vercel_api_token
  team      = var.vercel_team
}
EOF

cat > "$TF_FRONTEND/environments/dev/variables.tf" << 'EOF'
variable "vercel_api_token" {
  description = "Token de API de Vercel"
  type        = string
  sensitive   = true
}

variable "vercel_team" {
  description = "Slug del equipo en Vercel (vacío = cuenta personal)"
  type        = string
  default     = ""
}

variable "git_repo" {
  description = "Repositorio Git (owner/repo)"
  type        = string
}

variable "api_url" {
  description = "URL del backend (dev usa Floci en localhost)"
  type        = string
  default     = "http://localhost:8080"
}
EOF

cat > "$TF_FRONTEND/environments/dev/main.tf" << 'EOF'
module "frontend" {
  source       = "../../modules/vercel-project"
  project_name = "my-app-dev"
  git_repo     = var.git_repo
  api_url      = var.api_url
}
EOF

touch "$TF_FRONTEND/environments/dev/outputs.tf"

# ---------------------------------------------------------------------------
# frontend/environments/staging/ y prod/ — misma estructura, distinto api_url
# ---------------------------------------------------------------------------
for env in staging prod; do
cat > "$TF_FRONTEND/environments/$env/providers.tf" << EOF
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    vercel = {
      source  = "vercel/vercel"
      version = "~> 2.0"
    }
  }
}

provider "vercel" {
  api_token = var.vercel_api_token
  team      = var.vercel_team
}
EOF

cat > "$TF_FRONTEND/environments/$env/variables.tf" << 'EOF'
variable "vercel_api_token" {
  description = "Token de API de Vercel"
  type        = string
  sensitive   = true
}

variable "vercel_team" {
  description = "Slug del equipo en Vercel (vacío = cuenta personal)"
  type        = string
  default     = ""
}

variable "git_repo" {
  description = "Repositorio Git (owner/repo)"
  type        = string
}

variable "api_url" {
  description = "URL del backend"
  type        = string
}
EOF

cat > "$TF_FRONTEND/environments/$env/main.tf" << EOF
module "frontend" {
  source       = "../../modules/vercel-project"
  project_name = "my-app-${env}"
  git_repo     = var.git_repo
  api_url      = var.api_url
}
EOF

  touch "$TF_FRONTEND/environments/$env/outputs.tf"
done

# ===========================================================================
# BACKEND — provider AWS / Floci
# ===========================================================================

# ---------------------------------------------------------------------------
# backend/modules/ — placeholders (heredan provider del entorno)
# ---------------------------------------------------------------------------
for mod in vpc eks rds; do
  touch "$TF_BACKEND/modules/$mod/main.tf"
  touch "$TF_BACKEND/modules/$mod/variables.tf"
  touch "$TF_BACKEND/modules/$mod/outputs.tf"
done

# ---------------------------------------------------------------------------
# backend/environments/dev/ — Floci (emulador AWS local, puerto 4566)
# ---------------------------------------------------------------------------
cat > "$TF_BACKEND/environments/dev/providers.tf" << 'EOF'
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
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
    ec2 = "http://localhost:4566"
    eks = "http://localhost:4566"
    rds = "http://localhost:4566"
    s3  = "http://localhost:4566"
    iam = "http://localhost:4566"
    sts = "http://localhost:4566"
  }
}
EOF

cat > "$TF_BACKEND/environments/dev/variables.tf" << 'EOF'
variable "aws_region" {
  description = "Región AWS"
  type        = string
  default     = "us-east-1"
}
EOF

touch "$TF_BACKEND/environments/dev/main.tf"
touch "$TF_BACKEND/environments/dev/outputs.tf"

# ---------------------------------------------------------------------------
# backend/environments/staging/ y prod/ — AWS real
# ---------------------------------------------------------------------------
for env in staging prod; do
cat > "$TF_BACKEND/environments/$env/providers.tf" << 'EOF'
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}
EOF

cat > "$TF_BACKEND/environments/$env/variables.tf" << 'EOF'
variable "aws_region" {
  description = "Región AWS"
  type        = string
  default     = "us-east-1"
}
EOF

  touch "$TF_BACKEND/environments/$env/main.tf"
  touch "$TF_BACKEND/environments/$env/outputs.tf"
done

log_ok "Estructura Terraform creada en $TERRAFORM_ROOT."
