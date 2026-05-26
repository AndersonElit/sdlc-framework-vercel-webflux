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
  "$TF_BACKEND/modules/eks" \
  "$TF_BACKEND/modules/rds" \
  "$TF_BACKEND/modules/iam" \
  "$TF_BACKEND/modules/cognito" \
  "$TF_BACKEND/modules/api-gateway" \
  "$TF_BACKEND/modules/secrets-manager" \
  "$TF_BACKEND/modules/ecr" \
  "$TF_BACKEND/environments/dev" \
  "$TF_BACKEND/environments/staging" \
  "$TF_BACKEND/environments/prod"

# ===========================================================================
# FRONTEND — provider Vercel
# ===========================================================================

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
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role" "nodes" {
  name               = "${var.project_name}-${var.environment}-eks-nodes"
  assume_role_policy = data.aws_iam_policy_document.nodes_assume_role.json
}

resource "aws_iam_role_policy_attachment" "nodes_worker" {
  role       = aws_iam_role.nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "nodes_cni" {
  role       = aws_iam_role.nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "nodes_ecr" {
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

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }

  depends_on = [aws_iam_role_policy_attachment.cluster_policy]
}

resource "aws_eks_node_group" "main" {
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
  description = "URL del OIDC issuer (para IRSA)"
  value       = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

output "node_group_arn" {
  description = "ARN del node group"
  value       = aws_eks_node_group.main.arn
}
EOF

log_ok "Módulo EKS listo."

# ===========================================================================
# BACKEND — módulo RDS
# ===========================================================================

log "Escribiendo módulo RDS..."

cat > "$TF_BACKEND/modules/rds/main.tf" << 'EOF'
resource "aws_db_subnet_group" "main" {
  name        = "${var.project_name}-${var.environment}-rds"
  description = "Subnet group para ${var.project_name} ${var.environment}"
  subnet_ids  = var.subnet_ids

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

resource "aws_db_instance" "main" {
  identifier        = "${var.project_name}-${var.environment}"
  engine            = "postgres"
  engine_version    = var.engine_version
  instance_class    = var.instance_class
  allocated_storage = var.allocated_storage
  storage_encrypted = var.environment != "dev"

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
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
EOF

cat > "$TF_BACKEND/modules/rds/outputs.tf" << 'EOF'
output "endpoint" {
  description = "Endpoint de conexión a RDS"
  value       = aws_db_instance.main.endpoint
}

output "port" {
  description = "Puerto de conexión a RDS"
  value       = aws_db_instance.main.port
}

output "db_name" {
  description = "Nombre de la base de datos"
  value       = aws_db_instance.main.db_name
}

output "identifier" {
  description = "Identificador de la instancia RDS"
  value       = aws_db_instance.main.identifier
}

output "arn" {
  description = "ARN de la instancia RDS"
  value       = aws_db_instance.main.arn
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
}

resource "aws_iam_policy" "ecr_pull" {
  name        = "${var.project_name}-${var.environment}-ecr-pull"
  description = "Allow pulling images from ECR"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "task_secrets" {
  role       = aws_iam_role.ecs_task.name
  policy_arn = aws_iam_policy.secrets_read.arn
}

resource "aws_iam_role_policy_attachment" "task_ecr" {
  role       = aws_iam_role.ecs_task.name
  policy_arn = aws_iam_policy.ecr_pull.arn
}
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

output "ecr_pull_policy_arn" {
  description = "ARN de la política de pull de ECR"
  value       = aws_iam_policy.ecr_pull.arn
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

  generate_secret                      = false
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["implicit", "code"]
  allowed_oauth_scopes                 = ["email", "openid", "profile"]

  callback_urls = var.callback_urls
  logout_urls   = var.logout_urls

  supported_identity_providers = ["COGNITO"]

  access_token_validity  = 1
  id_token_validity      = 1
  refresh_token_validity = 30

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }
}

resource "aws_cognito_user_pool_domain" "main" {
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
    ec2            = "http://localhost:4566"
    eks            = "http://localhost:4566"
    rds            = "http://localhost:4566"
    s3             = "http://localhost:4566"
    iam            = "http://localhost:4566"
    sts            = "http://localhost:4566"
    cognitoidp     = "http://localhost:4566"
    apigateway     = "http://localhost:4566"
    apigatewayv2   = "http://localhost:4566"
    secretsmanager = "http://localhost:4566"
    ecr            = "http://localhost:4566"
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

cat > "$TF_BACKEND/environments/dev/main.tf" << 'EOF'
locals {
  project_name = "my-app"
  environment  = "dev"
  services     = ["auth-svc", "user-svc", "order-svc"]
}

module "iam" {
  source       = "../../modules/iam"
  environment  = local.environment
  project_name = local.project_name
}

module "cognito" {
  source       = "../../modules/cognito"
  environment  = local.environment
  project_name = local.project_name
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

module "ecr" {
  source       = "../../modules/ecr"
  environment  = local.environment
  project_name = local.project_name
  services     = local.services
}
EOF

cat > "$TF_BACKEND/environments/dev/outputs.tf" << 'EOF'
output "api_endpoint" {
  description = "URL base del API Gateway"
  value       = module.api_gateway.api_endpoint
}

output "cognito_user_pool_id" {
  description = "ID del User Pool de Cognito"
  value       = module.cognito.user_pool_id
}

output "cognito_client_id" {
  description = "App Client ID de Cognito"
  value       = module.cognito.client_id
}

output "ecr_repository_urls" {
  description = "URLs de los repositorios ECR"
  value       = module.ecr.repository_urls
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

variable "project_name" {
  description = "Prefijo del proyecto"
  type        = string
}

variable "services" {
  description = "Lista de microservicios del proyecto"
  type        = list(string)
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
EOF

cat > "$TF_BACKEND/environments/$env/outputs.tf" << 'EOF'
output "api_endpoint" {
  description = "URL base del API Gateway"
  value       = module.api_gateway.api_endpoint
}

output "cognito_user_pool_id" {
  description = "ID del User Pool de Cognito"
  value       = module.cognito.user_pool_id
}

output "cognito_client_id" {
  description = "App Client ID de Cognito"
  value       = module.cognito.client_id
}

output "ecr_repository_urls" {
  description = "URLs de los repositorios ECR"
  value       = module.ecr.repository_urls
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
EOF

done

log_ok "Estructura Terraform creada en $TERRAFORM_ROOT."
