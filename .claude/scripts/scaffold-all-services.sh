#!/usr/bin/env bash

# ===========================================================================
# scaffold-all-services.sh — Generar el scaffolding de microservicios
#                            (backend Spring Boot hexagonal) y frontend Next.js
#
# Prerrequisitos:
#   - Python 3 disponible
#   - Los templates .claude/templates/maven_hexagonal_scaffold.py y
#     .claude/templates/nextjs_feature_scaffold.py deben existir
#
# Qué hace:
#   1. Verifica prerequisitos (python3, templates)
#   2. Crea el directorio backend/ y frontend/
#   3. Backend — genera microservicios Spring Boot hexagonal
#   4. Frontend — genera proyecto Next.js feature-based
#   5. Checklist de verificación de directorios generados
# ===========================================================================

set -euo pipefail

log()     { echo "[$(date '+%H:%M:%S')] $*"; }
log_ok()  { echo "[$(date '+%H:%M:%S')] OK  $*"; }
log_err() { echo "[$(date '+%H:%M:%S')] ERR $*" >&2; }
log_warn(){ echo "[$(date '+%H:%M:%S')] WRN $*"; }

BOLD="\033[1m"
RESET="\033[0m"
HEADER() { echo -e "\n${BOLD}━━━ $* ━━━${RESET}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TEMPLATES_DIR="$REPO_ROOT/.claude/templates"
MAVEN_TEMPLATE="$TEMPLATES_DIR/maven_hexagonal_scaffold.py"
NEXTJS_TEMPLATE="$TEMPLATES_DIR/nextjs_feature_scaffold.py"

BACKEND_DIR="$REPO_ROOT/backend"
FRONTEND_DIR="$REPO_ROOT/frontend"

# ──────────────────────────────────────────────────────────────────────────────
# Argumentos de línea de comandos
#
# --backend nombre:db:messaging:puerto   (repetible, obligatorio)
#   Define un microservicio backend con su base de datos, mensajería y puerto.
#   Se puede usar tantas veces como servicios se desee generar.
#   Ejemplo:
#     --backend seguridad-service:postgres:none:8081
#
# --frontend nombre                       (opcional)
#   Nombre del proyecto frontend Next.js a generar.
#   Si se omite, no se genera frontend.
#   Ejemplo:
#     --frontend flexicredit-web
# ──────────────────────────────────────────────────────────────────────────────
BACKEND_SERVICES=()
FRONTEND_NAME=""
HAS_FRONTEND=0

usage() {
  cat <<EOF
Uso: $0 --backend nombre:db:messaging:puerto [--backend ...] [--frontend nombre]

  --backend   Par nombre:db:messaging:puerto. Repetir una vez por servicio (obligatorio).
              db       = postgres | mongo
              messaging = none | kafka-producer | kafka-consumer | rabbit-producer | rabbit-consumer
              puerto   = número de puerto HTTP

  --frontend  Nombre del proyecto frontend Next.js (opcional).
              Si se omite, no se genera frontend.

Ejemplo:
  bash $0 \\
    --backend seguridad-service:postgres:none:8081 \\
    --backend clientes-service:postgres:kafka-producer:8082 \\
    --backend configuracion-service:postgres:kafka-producer:8083 \\
    --frontend flexicredit-web

EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend)
      if [[ -z "${2:-}" ]]; then
        log_err "--backend requiere un valor (nombre:db:messaging:puerto)."
        exit 1
      fi
      BACKEND_SERVICES+=("$2")
      shift 2
      ;;
    --backend=*)
      VAL="${1#*=}"
      if [[ -z "$VAL" ]]; then
        log_err "--backend requiere un valor (nombre:db:messaging:puerto)."
        exit 1
      fi
      BACKEND_SERVICES+=("$VAL")
      shift
      ;;
    --frontend)
      if [[ -z "${2:-}" ]]; then
        log_err "--frontend requiere un valor (nombre del proyecto)."
        exit 1
      fi
      FRONTEND_NAME="$2"
      HAS_FRONTEND=1
      shift 2
      ;;
    --frontend=*)
      FRONTEND_NAME="${1#*=}"
      if [[ -z "$FRONTEND_NAME" ]]; then
        log_err "--frontend requiere un valor (nombre del proyecto)."
        exit 1
      fi
      HAS_FRONTEND=1
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      log_err "Argumento desconocido: $1"
      usage
      ;;
  esac
done

if [[ "${#BACKEND_SERVICES[@]}" -eq 0 ]]; then
  log_err "Se requiere al menos un argumento --backend."
  log_err "Ejecute con --help para ver la ayuda."
  exit 1
fi

log "Servicios backend: ${#BACKEND_SERVICES[@]} definidos."
if [[ "$HAS_FRONTEND" -eq 1 ]]; then
  log "Frontend: $FRONTEND_NAME"
else
  log "Frontend: omitido (no se especificó --frontend)."
fi

# ──────────────────────────────────────────────────────────────────────────────
# 1. Validación de prerequisitos
# ──────────────────────────────────────────────────────────────────────────────
HEADER "1. Verificando prerequisitos"

if ! command -v python3 &>/dev/null; then
  log_err "python3 no está instalado. Abortando."
  exit 1
fi
log_ok "python3 encontrado ($(command -v python3))."

if [[ ! -f "$MAVEN_TEMPLATE" ]]; then
  log_err "Template no encontrado: $MAVEN_TEMPLATE"
  exit 1
fi
log_ok "Template Maven hexagonal encontrado: $MAVEN_TEMPLATE"

if [[ "$HAS_FRONTEND" -eq 1 ]]; then
  if [[ ! -f "$NEXTJS_TEMPLATE" ]]; then
    log_err "Template no encontrado: $NEXTJS_TEMPLATE"
    exit 1
  fi
  log_ok "Template Next.js encontrado: $NEXTJS_TEMPLATE"
else
  log "Template Next.js: omitido (no se generará frontend)."
fi

# Validar formato de cada --backend
for svc_spec in "${BACKEND_SERVICES[@]}"; do
  IFS=':' read -r name db messaging port <<< "$svc_spec"
  if [[ -z "$name" || -z "$db" || -z "$messaging" || -z "$port" ]]; then
    log_err "Formato inválido en --backend: '$svc_spec' (esperado nombre:db:messaging:puerto)."
    exit 1
  fi
done

# ──────────────────────────────────────────────────────────────────────────────
# 2. Crear directorios base
# ──────────────────────────────────────────────────────────────────────────────
HEADER "2. Creando directorios backend/ y frontend/"

mkdir -p "$BACKEND_DIR"
log_ok "Directorio backend/ creado: $BACKEND_DIR"

if [[ "$HAS_FRONTEND" -eq 1 ]]; then
  mkdir -p "$FRONTEND_DIR"
  log_ok "Directorio frontend/ creado: $FRONTEND_DIR"
fi

# ──────────────────────────────────────────────────────────────────────────────
# 3. Generar scaffolding de microservicios backend
# ──────────────────────────────────────────────────────────────────────────────
HEADER "3. Generando microservicios Spring Boot (${#BACKEND_SERVICES[@]} servicios)"

BACKEND_FAILED=()

for svc_spec in "${BACKEND_SERVICES[@]}"; do
  IFS=':' read -r name db messaging port <<< "$svc_spec"

  if [[ -d "$BACKEND_DIR/$name" ]]; then
    log_warn "$name — directorio ya existe; omitiendo."
    continue
  fi

  log "Generando $name (db=$db, messaging=$messaging, port=$port)..."
  if (cd "$BACKEND_DIR" && python3 "$MAVEN_TEMPLATE" -n "$name" -d "$db" -m "$messaging" -p "$port"); then
    log_ok "$name generado."
  else
    log_err "$name — falló la generación."
    BACKEND_FAILED+=("$name")
  fi
done

# ──────────────────────────────────────────────────────────────────────────────
# 4. Generar scaffolding frontend
# ──────────────────────────────────────────────────────────────────────────────
if [[ "$HAS_FRONTEND" -eq 1 ]]; then
  HEADER "4. Generando frontend Next.js"

  FRONTEND_FAILED=0

  if [[ -d "$FRONTEND_DIR/$FRONTEND_NAME" ]]; then
    log_warn "frontend/$FRONTEND_NAME — directorio ya existe; omitiendo."
  else
    log "Generando $FRONTEND_NAME..."
    if (cd "$FRONTEND_DIR" && python3 "$NEXTJS_TEMPLATE" -n "$FRONTEND_NAME"); then
      log_ok "$FRONTEND_NAME generado."
    else
      log_err "$FRONTEND_NAME — falló la generación."
      FRONTEND_FAILED=1
    fi
  fi
else
  FRONTEND_FAILED=0
  HEADER "4. Frontend omitido"
  log "No se especificó --frontend; sin frontend que generar."
fi

# ──────────────────────────────────────────────────────────────────────────────
# 5. Checklist de verificación
# ──────────────────────────────────────────────────────────────────────────────
HEADER "5. Checklist de verificación"

PASS="✓"
FAIL="✗"
checklist_ok=0

check_item() {
  local desc="$1" result="$2"
  if [[ "$result" -eq 0 ]]; then
    echo -e "  ${PASS} $desc"
  else
    echo -e "  ${FAIL} $desc"
    checklist_ok=1
  fi
}

# Verificar cada microservicio backend
for svc_spec in "${BACKEND_SERVICES[@]}"; do
  IFS=':' read -r name db messaging port <<< "$svc_spec"
  POM="$BACKEND_DIR/$name/pom.xml"
  [[ -f "$POM" ]] && check_item "$name — pom.xml existe" 0 \
                    || check_item "$name — pom.xml existe" 1
done

# Verificar frontend
if [[ "$HAS_FRONTEND" -eq 1 ]]; then
  PACKAGE_JSON="$FRONTEND_DIR/$FRONTEND_NAME/package.json"
  [[ -f "$PACKAGE_JSON" ]] && check_item "$FRONTEND_NAME — package.json existe" 0 \
                              || check_item "$FRONTEND_NAME — package.json existe" 1
fi

echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 6. Resumen
# ──────────────────────────────────────────────────────────────────────────────
HEADER "Resumen"

GENERATED_COUNT=$(find "$BACKEND_DIR" -maxdepth 1 -mindepth 1 -type d -name "*-service" 2>/dev/null | wc -l)
echo ""
printf "  %-35s %s\n" "Microservicios backend" "${GENERATED_COUNT} generados"
if [[ "$HAS_FRONTEND" -eq 1 ]]; then
  printf "  %-35s %s\n" "Frontend" "$([[ -d "$FRONTEND_DIR/$FRONTEND_NAME" ]] && echo "$FRONTEND_NAME" || echo "NO generado")"
else
  printf "  %-35s %s\n" "Frontend" "omitido"
fi
echo ""

if [[ $checklist_ok -ne 0 ]] || [[ $FRONTEND_FAILED -ne 0 ]] || [[ ${#BACKEND_FAILED[@]} -gt 0 ]]; then
  if [[ ${#BACKEND_FAILED[@]} -gt 0 ]]; then
    log_err "Servicios backend fallidos: ${BACKEND_FAILED[*]}"
  fi
  if [[ $FRONTEND_FAILED -ne 0 ]]; then
    log_err "Frontend fallido: $FRONTEND_NAME"
  fi
  exit 1
fi

log_ok "Scaffolding completado exitosamente."

# ──────────────────────────────────────────────────────────────────────────────
# 7. Compilación backend
# ──────────────────────────────────────────────────────────────────────────────
HEADER "7. Compilación backend"

log "Ejecutando compile-services.sh..."
if bash "$SCRIPT_DIR/compile-services.sh"; then
  log_ok "Compilación backend completada."
else
  log_err "Compilación backend falló."
  exit 1
fi

# ──────────────────────────────────────────────────────────────────────────────
# 8. Verificación frontend
# ──────────────────────────────────────────────────────────────────────────────
if [[ "$HAS_FRONTEND" -eq 1 ]]; then
  HEADER "8. Verificación frontend"

  log "Ejecutando verify-frontend.sh..."
  if bash "$SCRIPT_DIR/verify-frontend.sh"; then
    log_ok "Verificación frontend completada."
  else
    log_err "Verificación frontend falló."
    exit 1
  fi
else
  HEADER "8. Verificación frontend omitida"
  log "No se especificó --frontend; sin frontend que verificar."
fi

# ──────────────────────────────────────────────────────────────────────────────
# 9. Secrets floci
# ──────────────────────────────────────────────────────────────────────────────
HEADER "9. Secrets floci"

log "Ejecutando create-all-secrets-dev.sh..."
if bash "$SCRIPT_DIR/create-all-secrets-dev.sh"; then
  log_ok "Secrets creados en floci."
else
  log_err "Creación de secrets falló."
  exit 1
fi

# ──────────────────────────────────────────────────────────────────────────────
# 10. Terraform apply (dev — ECR + Secrets Manager)
# ──────────────────────────────────────────────────────────────────────────────
HEADER "10. Terraform apply (dev)"

TERRAFORM_DEV_DIR="$REPO_ROOT/terraform/backend/environments/dev"

if [[ ! -d "$TERRAFORM_DEV_DIR" ]]; then
  log_err "Directorio Terraform no encontrado: $TERRAFORM_DEV_DIR"
  exit 1
fi

log "Aplicando Terraform en $TERRAFORM_DEV_DIR..."
if (cd "$TERRAFORM_DEV_DIR" && terraform apply -auto-approve); then
  log_ok "Terraform apply completado."
else
  log_err "Terraform apply falló."
  exit 1
fi

# ──────────────────────────────────────────────────────────────────────────────
# 11. Verificación — repositorios ECR en floci
# ──────────────────────────────────────────────────────────────────────────────
HEADER "11. Verificación ECR en floci"

log "Listando repositorios ECR en floci (localhost:4566)..."
aws --endpoint-url=http://localhost:4566 ecr describe-repositories \
  --region us-east-1 \
  --query 'repositories[].repositoryName' \
  --output table \
  && log_ok "Repositorios ECR verificados." \
  || log_warn "No se pudieron listar los repositorios ECR (floci puede no estar levantado)."

# ──────────────────────────────────────────────────────────────────────────────
# 12. Verificación — secrets en floci
# ──────────────────────────────────────────────────────────────────────────────
HEADER "12. Verificación de secrets en floci"

log "Listando secrets flexicredit/dev/* en Secrets Manager de floci..."
aws --endpoint-url=http://localhost:4566 secretsmanager list-secrets \
  --region us-east-1 \
  --query 'SecretList[?starts_with(Name, `flexicredit/dev/`)].Name' \
  --output table \
  && log_ok "Secrets verificados." \
  || log_warn "No se pudieron listar los secrets (floci puede no estar levantado)."

log_ok "Pipeline post-scaffolding completado exitosamente."
