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
# Estructura base de Terraform
# ---------------------------------------------------------------------------
TERRAFORM_ROOT="${PROJECT_ROOT:-$(pwd)}/terraform"

log "Creando estructura Terraform en $TERRAFORM_ROOT..."

mkdir -p \
  "$TERRAFORM_ROOT/modules/vpc" \
  "$TERRAFORM_ROOT/modules/eks" \
  "$TERRAFORM_ROOT/modules/rds" \
  "$TERRAFORM_ROOT/environments/dev" \
  "$TERRAFORM_ROOT/environments/staging" \
  "$TERRAFORM_ROOT/environments/prod" \
  "$TERRAFORM_ROOT/shared"

# ---------------------------------------------------------------------------
# shared/ — versiones y variables comunes a todos los entornos
# ---------------------------------------------------------------------------
cat > "$TERRAFORM_ROOT/shared/versions.tf" << 'EOF'
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    vercel = {
      source  = "vercel/vercel"
      version = "~> 2.0"
    }
  }
}
EOF

cat > "$TERRAFORM_ROOT/shared/variables.tf" << 'EOF'
variable "vercel_api_token" {
  description = "Token de API de Vercel"
  type        = string
  sensitive   = true
}

variable "vercel_team" {
  description = "Slug del equipo en Vercel (dejar vacío para cuenta personal)"
  type        = string
  default     = ""
}

variable "aws_region" {
  description = "Región AWS"
  type        = string
  default     = "us-east-1"
}
EOF

touch "$TERRAFORM_ROOT/shared/main.tf"
touch "$TERRAFORM_ROOT/shared/outputs.tf"

# ---------------------------------------------------------------------------
# environments/dev/ — Floci (emulador AWS local) + Vercel preview
# ---------------------------------------------------------------------------
cat > "$TERRAFORM_ROOT/environments/dev/providers.tf" << 'EOF'
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    vercel = {
      source  = "vercel/vercel"
      version = "~> 2.0"
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

# Vercel — despliegue de preview para dev
provider "vercel" {
  api_token = var.vercel_api_token
  team      = var.vercel_team
}
EOF

cat > "$TERRAFORM_ROOT/environments/dev/variables.tf" << 'EOF'
variable "vercel_api_token" {
  description = "Token de API de Vercel"
  type        = string
  sensitive   = true
}

variable "vercel_team" {
  description = "Slug del equipo en Vercel"
  type        = string
  default     = ""
}
EOF

touch "$TERRAFORM_ROOT/environments/dev/main.tf"
touch "$TERRAFORM_ROOT/environments/dev/outputs.tf"

# ---------------------------------------------------------------------------
# environments/staging/ — AWS real + Vercel preview
# ---------------------------------------------------------------------------
cat > "$TERRAFORM_ROOT/environments/staging/providers.tf" << 'EOF'
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    vercel = {
      source  = "vercel/vercel"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Vercel — despliegue de preview para staging
provider "vercel" {
  api_token = var.vercel_api_token
  team      = var.vercel_team
}
EOF

cat > "$TERRAFORM_ROOT/environments/staging/variables.tf" << 'EOF'
variable "aws_region" {
  description = "Región AWS"
  type        = string
  default     = "us-east-1"
}

variable "vercel_api_token" {
  description = "Token de API de Vercel"
  type        = string
  sensitive   = true
}

variable "vercel_team" {
  description = "Slug del equipo en Vercel"
  type        = string
  default     = ""
}
EOF

touch "$TERRAFORM_ROOT/environments/staging/main.tf"
touch "$TERRAFORM_ROOT/environments/staging/outputs.tf"

# ---------------------------------------------------------------------------
# environments/prod/ — AWS real + Vercel producción
# ---------------------------------------------------------------------------
cat > "$TERRAFORM_ROOT/environments/prod/providers.tf" << 'EOF'
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    vercel = {
      source  = "vercel/vercel"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Vercel — despliegue de producción
provider "vercel" {
  api_token = var.vercel_api_token
  team      = var.vercel_team
}
EOF

cat > "$TERRAFORM_ROOT/environments/prod/variables.tf" << 'EOF'
variable "aws_region" {
  description = "Región AWS"
  type        = string
  default     = "us-east-1"
}

variable "vercel_api_token" {
  description = "Token de API de Vercel"
  type        = string
  sensitive   = true
}

variable "vercel_team" {
  description = "Slug del equipo en Vercel"
  type        = string
  default     = ""
}
EOF

touch "$TERRAFORM_ROOT/environments/prod/main.tf"
touch "$TERRAFORM_ROOT/environments/prod/outputs.tf"

# ---------------------------------------------------------------------------
# modules/ — placeholders para recursos (sin bloque provider, lo heredan)
# ---------------------------------------------------------------------------
for mod in vpc eks rds; do
  touch "$TERRAFORM_ROOT/modules/$mod/main.tf"
  touch "$TERRAFORM_ROOT/modules/$mod/variables.tf"
  touch "$TERRAFORM_ROOT/modules/$mod/outputs.tf"
done

log_ok "Estructura Terraform creada en $TERRAFORM_ROOT."
