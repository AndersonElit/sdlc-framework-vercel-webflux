#!/usr/bin/env bash
#
# Genera el repositorio `jenkins-shared-library` con los pasos reutilizables
# (vars/) que invocan los Jenkinsfile emitidos por los scaffolds del proyecto:
#   - maven_hexagonal_scaffold.py  (backend)
#   - nextjs_feature_scaffold.py   (frontend, reutiliza notify)
#
# Ref: docs/cicd/PLAN-CICD-Jenkins.md §3.1 y §4.
#
# Uso:
#   bash .claude/scripts/jenkins-shared-library-builder.sh [-o DIR] [--no-git]
#
#   -o DIR     Directorio de salida (por defecto: ./jenkins-shared-library)
#   --no-git   No inicializar repositorio git ni hacer commit inicial

set -euo pipefail

log() { echo "[$(date '+%H:%M:%S')] $*"; }
log_ok() { echo "[$(date '+%H:%M:%S')] OK  $*"; }
log_err() { echo "[$(date '+%H:%M:%S')] ERR $*" >&2; }

# ---------------------------------------------------------------------------
# Argumentos
# ---------------------------------------------------------------------------
OUT_DIR="jenkins-shared-library"
DO_GIT=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output) OUT_DIR="$2"; shift 2 ;;
    --no-git) DO_GIT=0; shift ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) log_err "Argumento desconocido: $1"; exit 1 ;;
  esac
done

if [[ -e "$OUT_DIR" ]]; then
  log_err "El directorio '$OUT_DIR' ya existe. Elimínalo o usa -o para otro destino."
  exit 1
fi

log "Creando estructura de la Shared Library en: $OUT_DIR"
mkdir -p "$OUT_DIR/vars" "$OUT_DIR/src/org/flexicredit" "$OUT_DIR/resources"

# ---------------------------------------------------------------------------
# vars/ — pasos reutilizables (cada archivo define call(...))
# ---------------------------------------------------------------------------

# computeImageTag — <version-maven>-<git-sha-corto> (§3.3)
cat > "$OUT_DIR/vars/computeImageTag.groovy" <<'EOF'
// Calcula un tag inmutable: <version-maven>-<git-sha-corto>. Ref: §3.3.
def call() {
    def version = sh(
        script: 'mvn -q -DforceStdout help:evaluate -Dexpression=project.version',
        returnStdout: true
    ).trim()
    def shortSha = sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()
    return "${version}-${shortSha}"
}
EOF

# buildBackendService — build + unit tests Maven multimódulo (§4 stage 2)
cat > "$OUT_DIR/vars/buildBackendService.groovy" <<'EOF'
// Build + tests unitarios respetando la regla de dependencias hexagonal
// (domain -> application -> infrastructure -> entrypoints). Ref: §4 stage 2.
def call(Map args = [:]) {
    sh 'mvn -B --no-transfer-progress clean verify -DskipITs'
    junit testResults: '**/target/surefire-reports/*.xml', allowEmptyResults: true
}
EOF

# runIntegrationTests — Testcontainers (§4 stage 3)
cat > "$OUT_DIR/vars/runIntegrationTests.groovy" <<'EOF'
// Tests de integración (R2DBC/Mongo/Kafka) con Testcontainers. Ref: §4 stage 3.
def call(Map args = [:]) {
    def dbType = args.dbType ?: 'postgres'
    sh "mvn -B --no-transfer-progress failsafe:integration-test failsafe:verify -Ddb.type=${dbType}"
    junit testResults: '**/target/failsafe-reports/*.xml', allowEmptyResults: true
}
EOF

# runQualityGates — SonarQube + quality gate (§4 stage 4)
cat > "$OUT_DIR/vars/runQualityGates.groovy" <<'EOF'
// Análisis estático + espera del quality gate. Falla si el gate = ERROR. Ref: §4 stage 4.
def call(Map args = [:]) {
    def sonarEnv = args.sonarEnv ?: 'sonarqube'
    withSonarQubeEnv(sonarEnv) {
        sh 'mvn -B --no-transfer-progress sonar:sonar'
    }
    timeout(time: 10, unit: 'MINUTES') {
        def qg = waitForQualityGate()
        if (qg.status != 'OK') {
            error "Quality gate en estado: ${qg.status}"
        }
    }
}
EOF

# runSecurityScans — OWASP Dependency Check + escaneo de secretos (§4 stage 5)
cat > "$OUT_DIR/vars/runSecurityScans.groovy" <<'EOF'
// OWASP Dependency Check (CVEs) + escaneo de secretos. Falla ante hallazgo crítico. Ref: §4 stage 5.
def call(Map args = [:]) {
    def failOnCvss = args.failOnCvss ?: '9'
    sh "mvn -B --no-transfer-progress org.owasp:dependency-check-maven:check -DfailBuildOnCVSS=${failOnCvss}"
    // Escaneo de secretos (gitleaks). Sustituible por trufflehog según §11.
    sh 'gitleaks detect --source . --no-banner --redact --exit-code 1'
}
EOF

# buildAndPushImage — Kaniko build + push a ECR (§4 stage 6)
cat > "$OUT_DIR/vars/buildAndPushImage.groovy" <<'EOF'
// Construye la imagen multi-stage con Kaniko y la publica en ECR.
// Producción usa solo el tag inmutable; otros ambientes añaden 'latest'. Ref: §3.3 / §4 stage 6.
def call(Map args = [:]) {
    def ecrRepo  = args.ecrRepo  ?: error('buildAndPushImage: falta ecrRepo')
    def imageTag = args.imageTag ?: error('buildAndPushImage: falta imageTag')
    def registry = env.ECR_REGISTRY ?: error('buildAndPushImage: falta env.ECR_REGISTRY')

    def destinations = "--destination ${registry}/${ecrRepo}:${imageTag}"
    if (env.DEPLOY_ENV != 'prod') {
        destinations += " --destination ${registry}/${ecrRepo}:latest"
    }

    container('kaniko') {
        sh """
            /kaniko/executor \\
              --context dir://${WORKSPACE} \\
              --dockerfile Dockerfile \\
              ${destinations}
        """
    }
}
EOF

# scanImage — Trivy (§4 stage 7)
cat > "$OUT_DIR/vars/scanImage.groovy" <<'EOF'
// Escaneo de la imagen publicada con Trivy. Falla ante CVE crítico. Ref: §4 stage 7.
def call(Map args = [:]) {
    def ecrRepo  = args.ecrRepo  ?: error('scanImage: falta ecrRepo')
    def imageTag = args.imageTag ?: error('scanImage: falta imageTag')
    def registry = env.ECR_REGISTRY ?: error('scanImage: falta env.ECR_REGISTRY')
    def image = "${registry}/${ecrRepo}:${imageTag}"
    sh "trivy image --exit-code 1 --severity CRITICAL --no-progress ${image}"
}
EOF

# deployToEks — helm upgrade --install por ambiente (§4 stage 8)
cat > "$OUT_DIR/vars/deployToEks.groovy" <<'EOF'
// Despliegue a EKS con Helm usando los valores del ambiente. Ref: §4 stage 8 / §7.
def call(Map args = [:]) {
    def service   = args.service   ?: error('deployToEks: falta service')
    def namespace = args.namespace ?: error('deployToEks: falta namespace')
    def envName   = args.env       ?: error('deployToEks: falta env')
    def imageTag  = args.imageTag  ?: error('deployToEks: falta imageTag')
    def registry  = env.ECR_REGISTRY ?: error('deployToEks: falta env.ECR_REGISTRY')

    container('deploy') {
        sh """
            helm upgrade --install ${service} ./helm/${service} \\
              --namespace ${namespace} --create-namespace \\
              --values ./helm/${service}/values-${envName}.yaml \\
              --set image.repository=${registry}/${service} \\
              --set image.tag=${imageTag} \\
              --wait --timeout 5m
        """
    }
}
EOF

# runSmokeTests — verificación post-deploy (§4 stage 9)
cat > "$OUT_DIR/vars/runSmokeTests.groovy" <<'EOF'
// Verifica readiness del servicio desplegado. Ref: §4 stage 9 / §7.
def call(Map args = [:]) {
    def service   = args.service   ?: error('runSmokeTests: falta service')
    def namespace = args.namespace ?: error('runSmokeTests: falta namespace')
    container('deploy') {
        sh """
            kubectl rollout status deployment/${service} -n ${namespace} --timeout=180s
            kubectl run smoke-${BUILD_NUMBER} --rm -i --restart=Never -n ${namespace} \\
              --image=curlimages/curl:8.8.0 -- \\
              curl -fsS http://${service}.${namespace}.svc.cluster.local:8080/actuator/health/readiness
        """
    }
}
EOF

# notify — notificaciones Slack/email (§4 stage 10 / §9). Reutilizado por frontend.
cat > "$OUT_DIR/vars/notify.groovy" <<'EOF'
// Notificación de resultado a Slack (con fallback a log). Ref: §4 stage 10 / §9.
def call(Map args = [:]) {
    def status  = args.status  ?: currentBuild.currentResult
    def service = args.service ?: env.JOB_NAME
    def envName = args.env     ?: '-'
    def color   = status == 'SUCCESS' ? 'good' : 'danger'
    def message = "[${status}] ${service} (${envName}) — ${env.JOB_NAME} #${env.BUILD_NUMBER}\n${env.BUILD_URL}"

    try {
        slackSend(channel: '#cicd', color: color, message: message)
    } catch (ignored) {
        echo "Slack no configurado; resultado: ${message}"
    }
}
EOF

log_ok "Pasos vars/ generados (10 archivos)."

# ---------------------------------------------------------------------------
# src/ — clases auxiliares (§3.1)
# ---------------------------------------------------------------------------
cat > "$OUT_DIR/src/org/flexicredit/PipelineDefaults.groovy" <<'EOF'
package org.flexicredit

// Constantes y utilidades compartidas por los pasos de la Shared Library.
class PipelineDefaults implements Serializable {
    static final String SLACK_CHANNEL   = '#cicd'
    static final String SONAR_ENV       = 'sonarqube'
    static final String SECRETS_TOOL    = 'gitleaks'   // alternativa: trufflehog (§11)
    static final int    QG_TIMEOUT_MIN  = 10
    static final List<String> ENVIRONMENTS = ['dev', 'staging', 'prod']

    // Namespace de Kubernetes por ambiente (1:1 por defecto).
    static String namespaceFor(String env) {
        return env
    }
}
EOF

log_ok "Clase auxiliar src/org/flexicredit/PipelineDefaults.groovy generada."

# ---------------------------------------------------------------------------
# resources/ — plantilla de pod de agentes (referencia para JCasC)
# ---------------------------------------------------------------------------
mkdir -p "$OUT_DIR/resources/org/flexicredit"
cat > "$OUT_DIR/resources/org/flexicredit/podTemplate.yaml" <<'EOF'
# Plantilla de referencia para los pod templates de los agentes efímeros (§2).
# La configuración real del controller se versiona con JCasC; esto documenta
# los contenedores que los pasos vars/ esperan (container('kaniko'), etc.).
apiVersion: v1
kind: Pod
spec:
  containers:
    - name: maven
      image: maven:3.9-eclipse-temurin-21-alpine
      command: ['sleep']
      args: ['infinity']
    - name: kaniko
      image: gcr.io/kaniko-project/executor:debug
      command: ['sleep']
      args: ['infinity']
    - name: node
      image: node:20-alpine
      command: ['sleep']
      args: ['infinity']
    - name: deploy
      image: alpine/k8s:1.29.0   # incluye kubectl, helm y aws-cli
      command: ['sleep']
      args: ['infinity']
EOF

log_ok "Recurso resources/org/flexicredit/podTemplate.yaml generado."

# ---------------------------------------------------------------------------
# README + .gitignore
# ---------------------------------------------------------------------------
cat > "$OUT_DIR/README.md" <<'EOF'
# jenkins-shared-library

Shared Library de Jenkins con los pasos reutilizables del CI/CD de FlexiCredit.
Encapsula la lógica común para mantener los `Jenkinsfile` mínimos.
Ref: `docs/cicd/PLAN-CICD-Jenkins.md` §3.1.

## Uso desde un Jenkinsfile

```groovy
@Library('jenkins-shared-library@main') _
```

Registra esta librería en **Manage Jenkins → System → Global Pipeline Libraries**
con el nombre `jenkins-shared-library`, apuntando a este repositorio (rama `main`).

## Pasos disponibles (`vars/`)

| Step | Stage del pipeline (§4) |
|---|---|
| `computeImageTag()` | Checkout — tag inmutable `<version>-<sha>` |
| `buildBackendService()` | Build & Unit Tests |
| `runIntegrationTests(dbType: …)` | Integration Tests (Testcontainers) |
| `runQualityGates()` | Quality Gate (SonarQube) |
| `runSecurityScans()` | Security Scans (OWASP + secretos) |
| `buildAndPushImage(ecrRepo:, imageTag:)` | Build & Push Image (Kaniko → ECR) |
| `scanImage(ecrRepo:, imageTag:)` | Image Scan (Trivy) |
| `deployToEks(service:, namespace:, env:, imageTag:)` | Deploy a EKS (Helm) |
| `runSmokeTests(service:, namespace:)` | Smoke Tests (readiness) |
| `notify(status:, service:, env:)` | Notify (Slack/email) — también usado por el frontend |

## Requisitos del entorno

- `env.ECR_REGISTRY` disponible en el pipeline (registro ECR `<acct>.dkr.ecr.<region>.amazonaws.com`).
- Pod templates con los contenedores `maven`, `kaniko`, `node` y `deploy`
  (ver `resources/org/flexicredit/podTemplate.yaml`).
- Plugins: Pipeline Utility, SonarQube Scanner, Slack Notification, Kubernetes.
EOF

cat > "$OUT_DIR/.gitignore" <<'EOF'
*.log
.idea/
.vscode/
target/
EOF

log_ok "README.md y .gitignore generados."

# ---------------------------------------------------------------------------
# git init + commit inicial
# ---------------------------------------------------------------------------
if [[ "$DO_GIT" -eq 1 ]]; then
  if command -v git &>/dev/null; then
    git -C "$OUT_DIR" init -q -b main
    # Identidad local de respaldo solo si no hay ninguna configurada.
    if ! git -C "$OUT_DIR" config user.email &>/dev/null; then
      git -C "$OUT_DIR" config user.email "cicd@flexicredit.local"
      git -C "$OUT_DIR" config user.name "FlexiCredit CI"
    fi
    git -C "$OUT_DIR" add -A
    git -C "$OUT_DIR" commit -q -m "chore: scaffold jenkins-shared-library"
    log_ok "Repositorio git inicializado (rama main) con commit inicial."
  else
    log "git no está instalado; se omite la inicialización del repositorio."
  fi
fi

echo
log_ok "Shared Library lista en: $(cd "$OUT_DIR" && pwd)"
echo
echo "  Siguientes pasos:"
echo "  1. Publica el directorio como repositorio remoto (GitHub/GitLab)."
echo "  2. Regístralo en Jenkins: Manage Jenkins → System → Global Pipeline Libraries"
echo "     name=jenkins-shared-library, default version=main, SCM=este repo."
echo "  3. Los Jenkinsfile generados por los scaffolds ya lo referencian con"
echo "     @Library('jenkins-shared-library@main') _"
echo
