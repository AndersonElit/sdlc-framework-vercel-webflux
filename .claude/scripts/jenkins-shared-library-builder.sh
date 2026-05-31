#!/usr/bin/env bash
#
# Genera el repositorio `jenkins-shared-library` con los pasos reutilizables
# (vars/) que invocan los Jenkinsfile emitidos por los scaffolds del proyecto:
#   - maven_hexagonal_scaffold.py  (backend)
#   - nextjs_feature_scaffold.py   (frontend, reutiliza notify)
#
# Modelo CI/CD: Jenkins hace CI (build, test, scan, build & push de imagen a ECR)
# y, en lugar de desplegar, escribe el nuevo image tag en Git (bumpImageTag).
# ArgoCD hace CD por GitOps: observa helm/<service>/values-<env>.yaml y sincroniza
# el cluster EKS contra el estado deseado. La instalación de ArgoCD vive en el
# módulo Terraform 'argocd' (ver base-infrastructure-builder.sh).
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

# computeImageTag — <version-maven>-<git-sha-corto>
cat > "$OUT_DIR/vars/computeImageTag.groovy" <<'EOF'
// Calcula un tag inmutable: <version-maven>-<git-sha-corto>.
def call() {
    def version = sh(
        script: 'mvn -q -DforceStdout help:evaluate -Dexpression=project.version',
        returnStdout: true
    ).trim()
    def shortSha = sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()
    return "${version}-${shortSha}"
}
EOF

# buildBackendService — build + unit tests Maven multimódulo
cat > "$OUT_DIR/vars/buildBackendService.groovy" <<'EOF'
// Build + tests unitarios respetando la regla de dependencias hexagonal
// (domain -> application -> infrastructure -> entrypoints).
def call(Map args = [:]) {
    sh 'mvn -B --no-transfer-progress clean verify -DskipITs'
    junit testResults: '**/target/surefire-reports/*.xml', allowEmptyResults: true
}
EOF

# runIntegrationTests — Testcontainers
cat > "$OUT_DIR/vars/runIntegrationTests.groovy" <<'EOF'
// Tests de integración (R2DBC/Mongo/Kafka) con Testcontainers.
def call(Map args = [:]) {
    def dbType = args.dbType ?: 'postgres'
    sh "mvn -B --no-transfer-progress failsafe:integration-test failsafe:verify -Ddb.type=${dbType}"
    junit testResults: '**/target/failsafe-reports/*.xml', allowEmptyResults: true
}
EOF

# runQualityGates — SonarQube + quality gate
cat > "$OUT_DIR/vars/runQualityGates.groovy" <<'EOF'
// Análisis estático + espera del quality gate. Falla si el gate = ERROR.
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

# runSecurityScans — OWASP Dependency Check + escaneo de secretos
cat > "$OUT_DIR/vars/runSecurityScans.groovy" <<'EOF'
// OWASP Dependency Check (CVEs) + escaneo de secretos. Falla ante hallazgo crítico.
def call(Map args = [:]) {
    def failOnCvss = args.failOnCvss ?: '9'
    // OWASP corre en el contenedor maven (defaultContainer del pod backend).
    sh "mvn -B --no-transfer-progress org.owasp:dependency-check-maven:check -DfailBuildOnCVSS=${failOnCvss}"
    // Escaneo de secretos (gitleaks) en su propio contenedor. Sustituible por trufflehog.
    container('gitleaks') {
        sh 'gitleaks detect --source . --no-banner --redact --exit-code 1'
    }
}
EOF

# buildAndPushImage — Kaniko build + push a ECR
cat > "$OUT_DIR/vars/buildAndPushImage.groovy" <<'EOF'
// Construye la imagen multi-stage con Kaniko y la publica en ECR.
// Producción usa solo el tag inmutable; otros ambientes añaden 'latest'.
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

# scanImage — Trivy
cat > "$OUT_DIR/vars/scanImage.groovy" <<'EOF'
// Escaneo de la imagen publicada con Trivy. Falla ante CVE crítico.
def call(Map args = [:]) {
    def ecrRepo  = args.ecrRepo  ?: error('scanImage: falta ecrRepo')
    def imageTag = args.imageTag ?: error('scanImage: falta imageTag')
    def registry = env.ECR_REGISTRY ?: error('scanImage: falta env.ECR_REGISTRY')
    def image = "${registry}/${ecrRepo}:${imageTag}"
    container('trivy') {
        sh "trivy image --exit-code 1 --severity CRITICAL --no-progress ${image}"
    }
}
EOF

# bumpImageTag — actualiza el estado deseado en Git (GitOps). NO despliega.
cat > "$OUT_DIR/vars/bumpImageTag.groovy" <<'EOF'
// Frontera CI → CD. Tras publicar la imagen en ECR, este paso reescribe
// image.repository / image.tag en helm/<service>/values-<env>.yaml y commitea
// el cambio al repo del servicio. ArgoCD observa ese path y sincroniza el
// cluster contra el nuevo estado deseado (auto-sync en dev/staging; sync manual
// en prod). Jenkins nunca ejecuta helm/kubectl de despliegue: el CD vive en ArgoCD.
def call(Map args = [:]) {
    def service    = args.service  ?: error('bumpImageTag: falta service')
    def envName    = args.env      ?: error('bumpImageTag: falta env')
    def imageTag   = args.imageTag ?: error('bumpImageTag: falta imageTag')
    def registry   = env.ECR_REGISTRY ?: error('bumpImageTag: falta env.ECR_REGISTRY')
    def credId     = args.credentialsId ?: env.GITOPS_CREDENTIALS_ID ?: 'gitops-git-credentials'
    def valuesFile = "helm/${service}/values-${envName}.yaml"

    // Rama destino: la del build (multibranch) o la derivada de GIT_BRANCH.
    def branch = env.BRANCH_NAME
    if (!branch) { branch = (env.GIT_BRANCH ?: 'main').replaceFirst(/^origin\//, '') }

    // yq estático: edita el YAML sin alterar el resto del archivo.
    sh '''
        if ! command -v yq >/dev/null 2>&1 && [ ! -x /tmp/yq ]; then
          curl -fsSL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o /tmp/yq
          chmod +x /tmp/yq
        fi
    '''
    withEnv(["REPO_IMAGE=${registry}/${service}", "IMG_TAG=${imageTag}", "VALUES_FILE=${valuesFile}"]) {
        sh '''
            YQ=$(command -v yq || echo /tmp/yq)
            "$YQ" -i '.image.repository = strenv(REPO_IMAGE) | .image.tag = strenv(IMG_TAG)' "$VALUES_FILE"
        '''
    }

    withCredentials([usernamePassword(credentialsId: credId, usernameVariable: 'GIT_USER', passwordVariable: 'GIT_TOKEN')]) {
        withEnv(["VALUES_FILE=${valuesFile}", "SVC=${service}", "ENVN=${envName}", "TAG=${imageTag}", "TARGET_BRANCH=${branch}"]) {
            sh '''
                git config user.email "cicd@flexicredit.local"
                git config user.name  "FlexiCredit CI"
                git add "$VALUES_FILE"
                if git diff --cached --quiet; then
                  echo "Sin cambios en $VALUES_FILE (tag ya fijado); nada que commitear."
                  exit 0
                fi
                # '[skip ci]' evita que este commit de configuración re-dispare el pipeline.
                git commit -m "ci(deploy): $SVC -> $ENVN @ $TAG [skip ci]"
                AUTH_URL=$(git remote get-url origin | sed -E "s#https://#https://${GIT_USER}:${GIT_TOKEN}@#")
                git push "$AUTH_URL" "HEAD:${TARGET_BRANCH}"
            '''
        }
    }
}
EOF

# runSmokeTests — verificación post-sync (ambientes con auto-sync)
cat > "$OUT_DIR/vars/runSmokeTests.groovy" <<'EOF'
// Verifica readiness DESPUÉS de que ArgoCD haya sincronizado el nuevo tag.
// Solo aplica a ambientes con auto-sync (dev/staging): primero espera a que la
// imagen viva del deployment coincida con imageTag (evita validar la revisión
// anterior), luego confirma el rollout y prueba el endpoint de readiness.
// En prod el sync es manual en ArgoCD, así que el pipeline no ejecuta smoke aquí.
def call(Map args = [:]) {
    def service   = args.service   ?: error('runSmokeTests: falta service')
    def namespace = args.namespace ?: error('runSmokeTests: falta namespace')
    def imageTag  = args.imageTag  ?: error('runSmokeTests: falta imageTag')
    def cluster   = env.EKS_CLUSTER_NAME ?: error('runSmokeTests: falta env.EKS_CLUSTER_NAME')
    def region    = env.AWS_REGION ?: 'us-east-1'
    container('deploy') {
        sh "aws eks update-kubeconfig --name ${cluster} --region ${region}"
        sh """
            # Espera a que ArgoCD aplique el nuevo tag (imagen viva == *:${imageTag}).
            for i in \$(seq 1 60); do
              CURRENT=\$(kubectl get deploy/${service} -n ${namespace} \\
                -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
              echo "Esperando sync de ArgoCD — imagen actual: \${CURRENT:-<none>} (objetivo *:${imageTag})"
              case "\$CURRENT" in *:${imageTag}) break ;; esac
              sleep 5
            done
            kubectl rollout status deployment/${service} -n ${namespace} --timeout=180s
            kubectl run smoke-${BUILD_NUMBER} --rm -i --restart=Never -n ${namespace} \\
              --image=curlimages/curl:8.8.0 -- \\
              curl -fsS http://${service}.${namespace}.svc.cluster.local:8080/actuator/health/readiness
        """
    }
}
EOF

# notify — notificaciones Slack/email. Reutilizado por frontend.
cat > "$OUT_DIR/vars/notify.groovy" <<'EOF'
// Notificación de resultado a Slack (con fallback a log).
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
# src/ — clases auxiliares
# ---------------------------------------------------------------------------
cat > "$OUT_DIR/src/org/flexicredit/PipelineDefaults.groovy" <<'EOF'
package org.flexicredit

// Constantes y utilidades compartidas por los pasos de la Shared Library.
class PipelineDefaults implements Serializable {
    static final String SLACK_CHANNEL   = '#cicd'
    static final String SONAR_ENV       = 'sonarqube'
    static final String SECRETS_TOOL    = 'gitleaks'   // alternativa: trufflehog
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
# resources/ — pods de agentes (cargados con libraryResource desde los
# Jenkinsfile vía agent { kubernetes { yaml libraryResource(...) } }).
# El ServiceAccount jenkins-agent lleva la anotación IRSA (eks.amazonaws.com/
# role-arn) que la infra crea; así kaniko (ECR) y deploy (EKS) obtienen creds.
# ---------------------------------------------------------------------------
mkdir -p "$OUT_DIR/resources/org/flexicredit"

# Pod backend — build/test (maven), imagen (kaniko), escaneos (trivy/gitleaks),
# deploy (alpine/k8s) y un sidecar dind para Testcontainers.
cat > "$OUT_DIR/resources/org/flexicredit/podBackend.yaml" <<'EOF'
apiVersion: v1
kind: Pod
spec:
  serviceAccountName: jenkins-agent
  containers:
    - name: maven
      image: maven:3.9-eclipse-temurin-21
      command: ['sleep']
      args: ['infinity']
      env:
        # Testcontainers apunta al sidecar dind.
        - name: DOCKER_HOST
          value: tcp://localhost:2375
        - name: TESTCONTAINERS_RYUK_DISABLED
          value: "true"
      resources:
        requests:
          cpu: "1"
          memory: 2Gi
    - name: kaniko
      image: gcr.io/kaniko-project/executor:debug
      command: ['sleep']
      args: ['infinity']
    - name: trivy
      image: aquasec/trivy:0.53.0
      command: ['sleep']
      args: ['infinity']
    - name: gitleaks
      image: zricethezav/gitleaks:latest
      command: ['sleep']
      args: ['infinity']
    - name: deploy
      image: alpine/k8s:1.29.0   # incluye kubectl, helm y aws-cli
      command: ['sleep']
      args: ['infinity']
    # Sidecar Docker-in-Docker para los tests de integración (Testcontainers).
    - name: dind
      image: docker:25-dind
      securityContext:
        privileged: true
      env:
        - name: DOCKER_TLS_CERTDIR
          value: ""
EOF

# Pod frontend — solo Node (build + deploy a Vercel via CLI + Playwright).
cat > "$OUT_DIR/resources/org/flexicredit/podFrontend.yaml" <<'EOF'
apiVersion: v1
kind: Pod
spec:
  serviceAccountName: jenkins-agent
  containers:
    - name: node
      image: mcr.microsoft.com/playwright:v1.45.0-jammy   # Node 20 + navegadores
      command: ['sleep']
      args: ['infinity']
      resources:
        requests:
          cpu: 500m
          memory: 1Gi
EOF

log_ok "Pods de agentes (podBackend.yaml, podFrontend.yaml) generados."

# ---------------------------------------------------------------------------
# bootstrap/ — objetos Kubernetes previos (namespace + ServiceAccount IRSA).
# Se aplican una vez con un usuario con permisos de admin sobre el cluster:
#   kubectl apply -f bootstrap/jenkins-agent-rbac.yaml
# ---------------------------------------------------------------------------
mkdir -p "$OUT_DIR/bootstrap"
cat > "$OUT_DIR/bootstrap/jenkins-agent-rbac.yaml" <<'EOF'
# Namespace donde el controller lanza los pods agente + ServiceAccount IRSA.
# Sustituye <JENKINS_AGENT_ROLE_ARN> por el output agent_role_arn del módulo
# Jenkins de Terraform antes de aplicar.
apiVersion: v1
kind: Namespace
metadata:
  name: jenkins
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: jenkins-agent
  namespace: jenkins
  annotations:
    eks.amazonaws.com/role-arn: <JENKINS_AGENT_ROLE_ARN>
EOF

log_ok "Manifiesto bootstrap/jenkins-agent-rbac.yaml generado."

# ---------------------------------------------------------------------------
# docker/ — imagen del controller con JCasC + plugins horneados.
# Construir y publicar en ECR; apuntar var.jenkins_image del módulo Terraform a
# esta imagen. Los valores por ambiente se inyectan como variables de entorno
# (ECR_REGISTRY, EKS_CLUSTER_NAME, AWS_REGION, JENKINS_URL, etc.) en el docker run.
# ---------------------------------------------------------------------------
mkdir -p "$OUT_DIR/docker"

cat > "$OUT_DIR/docker/plugins.txt" <<'EOF'
# Plugins mínimos del controller (instalados con jenkins-plugin-cli).
configuration-as-code
kubernetes
workflow-aggregator
git
github
github-branch-source
pipeline-utility-steps
sonar
slack
credentials
credentials-binding
matrix-auth
EOF

cat > "$OUT_DIR/docker/Dockerfile" <<'EOF'
FROM jenkins/jenkins:lts-jdk21

# Salta el wizard y carga la config declarativa (JCasC).
ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false"
ENV CASC_JENKINS_CONFIG=/var/jenkins_home/casc/jenkins.yaml

COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

COPY jenkins.yaml /var/jenkins_home/casc/jenkins.yaml
EOF

# JCasC. Las claves ${VAR} se resuelven desde variables de entorno del contenedor,
# por lo que el mismo archivo sirve para dev/staging/prod (valores inyectados por
# el user_data de la instancia EC2 del controller).
cat > "$OUT_DIR/docker/jenkins.yaml" <<'EOF'
jenkins:
  systemMessage: "FlexiCredit CI/CD — configurado con JCasC"
  numExecutors: 0   # el controller no ejecuta builds; todo va a agentes EKS

  clouds:
    - kubernetes:
        name: "eks"
        # Endpoint del API server del cluster EKS (controller externo en EC2).
        serverUrl: "${EKS_API_SERVER}"
        namespace: "jenkins"
        # URL por la que los pods agente alcanzan al controller (ALB interno).
        jenkinsUrl: "${JENKINS_URL}"
        jenkinsTunnel: "${JENKINS_TUNNEL}"   # host:50000 del controller
        # Credencial kubeconfig (exec auth: aws eks get-token) generada en la EC2.
        credentialsId: "eks-kubeconfig"
        directConnection: false
        # Los pod templates vienen de los Jenkinsfile (yaml libraryResource);
        # no se declaran plantillas estáticas aquí.
        templates: []

  globalNodeProperties:
    - envVars:
        env:
          - key: "ECR_REGISTRY"
            value: "${ECR_REGISTRY}"
          - key: "EKS_CLUSTER_NAME"
            value: "${EKS_CLUSTER_NAME}"
          - key: "AWS_REGION"
            value: "${AWS_REGION}"

credentials:
  system:
    domainCredentials:
      - credentials:
          - string:
              scope: GLOBAL
              id: "sonar-token"
              secret: "${SONAR_TOKEN}"
          - string:
              scope: GLOBAL
              id: "slack-token"
              secret: "${SLACK_TOKEN}"
          - string:
              scope: GLOBAL
              id: "vercel-token"
              secret: "${VERCEL_TOKEN}"
          - string:
              scope: GLOBAL
              id: "vercel-org-id"
              secret: "${VERCEL_ORG_ID}"
          - string:
              scope: GLOBAL
              id: "vercel-project-id"
              secret: "${VERCEL_PROJECT_ID}"
          - file:
              scope: GLOBAL
              id: "eks-kubeconfig"
              fileName: "kubeconfig"
              secretBytes: "${base64:${readFile:/var/jenkins_home/.kube/config}}"
          # Credencial git (usuario + token) que usa bumpImageTag para hacer push
          # del image tag al repo del servicio (estado deseado que ArgoCD observa).
          - usernamePassword:
              scope: GLOBAL
              id: "gitops-git-credentials"
              username: "${GITOPS_GIT_USERNAME}"
              password: "${GITOPS_GIT_TOKEN}"

unclassified:
  location:
    url: "${JENKINS_URL}"
  globalLibraries:
    libraries:
      - name: "jenkins-shared-library"
        defaultVersion: "main"
        implicit: false
        retriever:
          modernSCM:
            scm:
              git:
                remote: "${SHARED_LIBRARY_REPO}"
  sonarGlobalConfiguration:
    installations:
      - name: "sonarqube"
        serverUrl: "${SONAR_URL}"
        credentialsId: "sonar-token"
  slackNotifier:
    teamDomain: "${SLACK_TEAM}"
    tokenCredentialId: "slack-token"
EOF

log_ok "Imagen del controller (docker/Dockerfile, plugins.txt, jenkins.yaml) generada."

# ---------------------------------------------------------------------------
# README + .gitignore
# ---------------------------------------------------------------------------
cat > "$OUT_DIR/README.md" <<'EOF'
# jenkins-shared-library

Shared Library de Jenkins con los pasos reutilizables del CI/CD de FlexiCredit.
Encapsula la lógica común para mantener los `Jenkinsfile` mínimos.

## Uso desde un Jenkinsfile

```groovy
@Library('jenkins-shared-library@main') _
```

Registra esta librería en **Manage Jenkins → System → Global Pipeline Libraries**
con el nombre `jenkins-shared-library`, apuntando a este repositorio (rama `main`).

## Pasos disponibles (`vars/`)

| Step | Stage del pipeline |
|---|---|
| `computeImageTag()` | Checkout — tag inmutable `<version>-<sha>` |
| `buildBackendService()` | Build & Unit Tests |
| `runIntegrationTests(dbType: …)` | Integration Tests (Testcontainers) |
| `runQualityGates()` | Quality Gate (SonarQube) |
| `runSecurityScans()` | Security Scans (OWASP + secretos) |
| `buildAndPushImage(ecrRepo:, imageTag:)` | Build & Push Image (Kaniko → ECR) |
| `scanImage(ecrRepo:, imageTag:)` | Image Scan (Trivy) |
| `bumpImageTag(service:, env:, imageTag:)` | Update GitOps — escribe el tag en `values-<env>.yaml` y commitea (frontera CI→CD) |
| `runSmokeTests(service:, namespace:, imageTag:)` | Smoke Tests (post-sync ArgoCD; solo no-prod) |
| `notify(status:, service:, env:)` | Notify (Slack/email) — también usado por el frontend |

## Modelo CI/CD (Jenkins = CI, ArgoCD = CD)

Jenkins **no despliega**. El pipeline termina su parte de CD escribiendo el nuevo
`image.tag` en `helm/<service>/values-<env>.yaml` (paso `bumpImageTag`) y commiteándolo
al repo del servicio. ArgoCD observa ese path y sincroniza el cluster:

- **dev/staging** → `syncPolicy.automated` (prune + selfHeal): se aplica solo al detectar el commit.
- **prod** → sync manual en ArgoCD (reemplaza el antiguo approval de Jenkins).

La instalación de ArgoCD y los `ApplicationSet`/`AppProject` los provee el módulo
Terraform `argocd` y los manifiestos `argocd-bootstrap/` (ver `base-infrastructure-builder.sh`).

## Modelo de ejecución

- **Controller**: contenedor Docker en EC2 + EBS (config declarativa con JCasC,
  ver `docker/`). No ejecuta builds (`numExecutors: 0`).
- **Agentes**: pods efímeros en EKS (Kubernetes plugin). Los Jenkinsfile cargan
  el pod con `agent { kubernetes { yaml libraryResource('org/flexicredit/podBackend.yaml') } }`
  (frontend: `podFrontend.yaml`).
- **Autenticación**: el ServiceAccount `jenkins-agent` usa IRSA. kaniko hace push
  a ECR; `bumpImageTag` hace push a Git con la credencial `gitops-git-credentials`;
  `runSmokeTests` usa el contenedor `deploy` (`aws eks update-kubeconfig` + kubectl).

## Variables de entorno / credenciales esperadas (inyectadas por JCasC / infra)

- `ECR_REGISTRY` — `<acct>.dkr.ecr.<region>.amazonaws.com`.
- `EKS_CLUSTER_NAME`, `AWS_REGION` — usados por `runSmokeTests`.
- `gitops-git-credentials` — credencial git (usuario + token con permiso de push al
  repo del servicio) usada por `bumpImageTag`. En el JCasC se alimenta de
  `GITOPS_GIT_USERNAME` / `GITOPS_GIT_TOKEN`. Opcional: `GITOPS_CREDENTIALS_ID`
  para sobreescribir el id por defecto.

## Puesta en marcha

1. Construye y publica la imagen del controller (`docker/`) en ECR; apunta
   `var.jenkins_image` del módulo Jenkins de Terraform a esa imagen.
2. Aplica `bootstrap/jenkins-agent-rbac.yaml` en el cluster (sustituyendo
   `<JENKINS_AGENT_ROLE_ARN>` por el output `agent_role_arn`).
3. Provee las credenciales referenciadas por el JCasC: `sonar-token`,
   `slack-token`, `vercel-*`, el kubeconfig `eks-kubeconfig` y
   `gitops-git-credentials` (token git con permiso de push para `bumpImageTag`).
4. Instala ArgoCD (módulo Terraform `argocd`) y aplica los manifiestos
   `argocd-bootstrap/` del ambiente; ArgoCD se encarga del CD por GitOps.

## Pods de agentes (`resources/org/flexicredit/`)

- `podBackend.yaml` — contenedores `maven` (default), `kaniko`, `trivy`,
  `gitleaks`, `deploy` (alpine/k8s) y sidecar `dind` (Testcontainers).
- `podFrontend.yaml` — contenedor `node` (build + deploy Vercel + Playwright).

## Plugins requeridos

Ver `docker/plugins.txt` (configuration-as-code, kubernetes, workflow-aggregator,
pipeline-utility-steps, sonar, slack, git/github, credentials, matrix-auth).
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
echo "  1. Publica el directorio como repositorio remoto (GitHub/GitLab) y úsalo"
echo "     como SHARED_LIBRARY_REPO (el JCasC registra la Global Pipeline Library)."
echo "  2. Construye y publica la imagen del controller (docker/) en ECR y apunta"
echo "     var.jenkins_image del módulo Jenkins de Terraform a esa imagen."
echo "  3. Aplica bootstrap/jenkins-agent-rbac.yaml en el cluster (namespace +"
echo "     ServiceAccount IRSA) usando el output agent_role_arn de Terraform."
echo "  4. Los Jenkinsfile generados por los scaffolds ya referencian la librería"
echo "     con @Library('jenkins-shared-library@main') _ y cargan los pods con"
echo "     libraryResource('org/flexicredit/podBackend.yaml' | 'podFrontend.yaml')."
echo
