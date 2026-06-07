# Plan de Migración: Docker Local → VPS Ubuntu Server 24.04 LTS

## Contexto

El framework actual levanta todas las herramientas de desarrollo como contenedores Docker en la máquina local. Esto genera una carga muy alta (CPU/RAM) al tener demasiados contenedores corriendo simultáneamente. La propuesta es mover estas herramientas a un VPS con Ubuntu Server 24.04 LTS (instalación minimal), instalándolas directamente como servicios del sistema (systemd). Docker permanece en el VPS únicamente porque floci lo requiere para su funcionamiento interno.

## Decisiones arquitectónicas

| Decisión | Antes | Ahora |
|---|---|---|
| **Frontend** | Desplegado en Vercel (Terraform provider `vercel/vercel`) | **Pod en K3s dentro del VPS** — imagen Docker construida por Jenkins, desplegada vía ArgoCD |
| **Container Registry** | ECR emulado por floci (Terraform módulo `ecr`) | **Gitea Package Registry** (OCI/Docker nativo) — ya instalado como servicio systemd, sin Terraform ni floci |
| **Base de datos relacional** | RDS emulado por floci (floci levanta un contenedor Docker PostgreSQL internamente, Terraform módulo `rds`) | **PostgreSQL instalado nativamente en el VPS** como servicio systemd — bases de datos creadas directamente, sin Terraform ni floci |

### Impacto del cambio de frontend

**Lo que desaparece:**
- Módulo Terraform `terraform/frontend/` completo (provider `vercel/vercel`, recurso `vercel_project`, variables de entorno Vercel).
- Variable `VERCEL_API_TOKEN` y `VERCEL_TEAM` de Secrets Manager.
- Job Jenkins de frontend que invocaba `vercel deploy`.
- **Módulo Terraform `terraform/backend/modules/ecr`** — ECR ya no se necesita; Gitea Package Registry reemplaza el registry de imágenes para todos los servicios (frontend + microservicios).
- Política IAM `ecr_pull` del módulo `iam` — los pods de K3s autentican contra Gitea, no contra ECR.
- Referencia `ECR_REGISTRY` en `setup-cicd-pipeline.sh` — reemplazada por la URL del Gitea Package Registry (`http://gitea:3000/<org>/<paquete>`).
- **Módulo Terraform `terraform/backend/modules/rds`** — PostgreSQL corre nativamente en el VPS; RDS (y el contenedor Docker que floci levantaba para emularlo) ya no se necesitan.
- Variable `db_password` de Secrets Manager para RDS — las credenciales de PostgreSQL se gestionan directamente en el VPS (archivo `pg_hba.conf` + usuario de sistema).
- Referencia `floci` a RDS en `init-dev-environment.sh` — las verificaciones de conectividad apuntan directamente al PostgreSQL local del VPS (`localhost:5432`).

**Lo que se agrega:**
- `Dockerfile` para el frontend (Next.js en modo standalone o nginx serving el build estático).
- Helm chart del frontend en el repo GitOps — `Deployment` + `Service` + `Ingress` (Traefik, que K3s incluye por defecto).
- Job Jenkins de frontend: `mvn`/`npm build` → `docker build` → push al registry interno de K3s → `bumpImageTag` → ArgoCD sync.
- Ingress con dominio o IP del VPS para exponer el frontend (ej. `http://<vps-ip>/` o `http://frontend.<dominio>`).

**Registry de imágenes:**
K3s no incluye un registry propio. Se usa el **Gitea Package Registry** (OCI/Docker nativo) — ya instalado en el VPS como servicio systemd. Reemplaza ECR para todos los servicios: frontend y microservicios backend.

```
Jenkins build → docker build → docker push gitea:3000/<org>/<servicio>:<tag>
                                     ↓
                              ArgoCD detecta nuevo tag (bumpImageTag)
                                     ↓
                              K3s pull desde Gitea registry → pod actualizado
```

Para que K3s pueda hacer pull desde Gitea se crea un `Secret` de tipo `kubernetes.io/dockerconfigjson` con las credenciales de Gitea, referenciado en `imagePullSecrets` de cada Deployment.

---

## Inventario de contenedores actuales

### Script: `base-infrastructure-builder.sh`

| Herramienta | Imagen Docker actual | Puerto(s) | Rol en el framework |
|---|---|---|---|
| **floci** | `floci/floci:latest` | 4566 | Emulador de AWS (Quarkus Native, MIT) — 47 servicios AWS en :4566. Arranca en 24ms, idle en **13 MiB**. Docker es requerido por floci mismo para emular ciertos servicios (Lambda, RDS, ElastiCache) |
| **MongoDB** | `mongo:7` | 27017 | Base de datos NoSQL para microservicios que lo requieran |
| **Apache Kafka** | `apache/kafka:3.7.0` | 9092 (interno), 29092 (externo) | Message broker en modo KRaft (sin ZooKeeper) |
| **Narayana LRA Coordinator** | `quay.io/jbosstm/lra-coordinator:latest` | 50000 | Coordinador de Saga (Long Running Actions) para el integration-service Camel |
| **WireMock** | `wiremock/wiremock:3.9.1` | 9999 | Simulador de sistemas externos para contract tests de las rutas Camel |
| **Gitea** | `gitea/gitea:1.22` | 3000 (HTTP), 2222 (SSH) | Servidor Git local — aloja repos de microservicios y jenkins-shared-library |
| **SonarQube** | `sonarqube:lts-community` | 9000 | Quality gate del pipeline CI — análisis estático de código |

### Script: `setup-cicd-pipeline.sh`

| Herramienta | Imagen Docker actual | Puerto(s) | Rol en el framework |
|---|---|---|---|
| **Jenkins Controller** | `${PROJECT_NAME}-jenkins:latest` (build local) | 8080 (UI), 50000 (agentes) | Servidor CI — orquesta builds, tests, push de imágenes y deploy vía ArgoCD |

### Script: `setup-observability.sh` (desplegado en K3d vía Helm)

> Estos corren actualmente como pods de Kubernetes dentro del cluster K3d (K3s en Docker). En el VPS se instalan sobre K3s nativo (sin Docker wrapper).

| Herramienta | Imagen/Chart actual | Puerto(s) | Rol en el framework |
|---|---|---|---|
| **Prometheus** | `prometheus-community/kube-prometheus-stack` | 9090 | Recolección de métricas del cluster y microservicios |
| **Grafana** | `prometheus-community/kube-prometheus-stack` | 3000 | Dashboards de métricas y logs |
| **Alertmanager** | `prometheus-community/kube-prometheus-stack` | 9093 | Gestión de alertas de Prometheus |
| **Jaeger** | `jaegertracing/jaeger` (all-in-one) | 16686 (UI), 4317 (OTLP gRPC) | Trazas distribuidas entre microservicios |
| **OTEL Collector** | `otel/opentelemetry-collector-contrib:0.96.0` | 4317 (gRPC), 4318 (HTTP) | Receptor de telemetría OTLP — enruta a Jaeger/Prometheus/Loki |
| **Loki** | `grafana/loki` | 3100 | Almacenamiento y consulta de logs del cluster |
| **Fluent Bit** | `fluent/fluent-bit` (DaemonSet) | — | Forwarding de logs de pods → Loki |
| **ArgoCD** | Terraform module `argocd` (Helm) | 8080 (interno) | GitOps CD — sincroniza Helm charts desde Gitea al cluster K3s |

### Infraestructura Kubernetes

| Componente | Situación actual | En VPS |
|---|---|---|
| **K3d** | K3s corriendo **dentro de Docker** (k3d) | Reemplazar por **K3s nativo** instalado directamente en el VPS |

---

## Propuesta de instalación en VPS Ubuntu Server

### Herramientas que se instalan como servicio systemd (sin Docker)

| # | Herramienta | Método de instalación | Notas |
|---|---|---|---|
| 1 | **PostgreSQL 16** | `apt install postgresql` (repositorio oficial postgresql.org) | Servicio `postgresql.service` — reemplaza RDS. Bases de datos creadas con `psql` directamente |
| 2 | **MongoDB 7** | `apt` (repositorio oficial mongodb.org) | Servicio `mongod.service` |
| 2 | **Apache Kafka 3.7** | Descarga binario + unidad systemd manual | KRaft mode — sin ZooKeeper |
| 3 | **Gitea 1.22** | Binario oficial + unidad systemd | SQLite como backend (dev) |
| 4 | **SonarQube LTS** | Zip oficial + unidad systemd | Requiere `vm.max_map_count=262144` y Java 17 |
| 5 | **Jenkins LTS** | `apt` (repositorio oficial jenkins.io) | Servicio `jenkins.service` |
| 6 | **WireMock 3.9** | JAR standalone (`java -jar wiremock.jar`) + unidad systemd | Requiere Java 17 |
| 7 | **Narayana LRA Coordinator** | JAR standalone + unidad systemd | Requiere Java 17 |

### floci — Docker permanece en el VPS por requerimiento de floci

Floci es un emulador AWS construido con Quarkus Native. Docker debe estar instalado en el VPS porque floci lo utiliza de dos formas:

1. **Para correr él mismo** — el contenedor `floci/floci:latest` es la distribución oficial.
2. **Para emular servicios AWS que requieren alta fidelidad** — floci levanta contenedores Docker internos para Lambda, RDS, ElastiCache, ECS, EKS y EC2. Los demás servicios (S3, SQS, SNS, DynamoDB, IAM, KMS, Cognito, ECR, EventBridge...) los maneja en proceso, sin contenedores adicionales.

El overhead es mínimo:

| Componente | Overhead |
|---|---|
| Docker daemon | ~30 MB RAM |
| Contenedor floci | **13 MiB RAM** en idle |
| Startup | **24 ms** |

**Gestión del ciclo de vida con floci CLI:**

```bash
curl -fsSL https://floci.io/install.sh | sh
floci start    # levanta floci/floci:latest
floci stop
floci status
floci logs
```

### Herramientas de sistema (prerequisitos del VPS)

Estas no son servicios — son binarios/CLIs que los scripts del framework invocan directamente.

#### Ecosistema Kubernetes / infraestructura

| Herramienta | Instalación | Usado por |
|---|---|---|
| **kubectl** | `curl -LO https://dl.k8s.io/release/stable.txt` + binario | `setup-observability.sh`, `setup-cicd-pipeline.sh` |
| **helm** | `curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \| bash` | `setup-observability.sh` — kube-prometheus-stack, Jaeger, Loki, Fluent Bit, ArgoCD |
| **terraform** | `apt` (repositorio HashiCorp) | `init-dev-environment.sh` — provisiona recursos en floci |
| **argocd CLI** | Binario oficial de ArgoCD releases | `setup-cicd-pipeline.sh` — gestiona apps GitOps |

#### AWS / floci

| Herramienta | Instalación | Usado por |
|---|---|---|
| **AWS CLI v2** | `curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip` | Todos los scripts — apunta a `http://localhost:4566` (floci) |
| **floci CLI** | `curl -fsSL https://floci.io/install.sh \| sh` | Gestión de ciclo de vida de floci (start/stop/status/logs) |

#### Java ecosystem

| Herramienta | Instalación | Usado por |
|---|---|---|
| **Java 21 LTS** | `apt install openjdk-21-jdk` | WireMock, LRA Coordinator, SonarQube (runtime), builds Maven |
| **Maven 3.9+** | `apt install maven` (o binario oficial) | `compile-services.sh` — compila microservicios; pipeline Jenkins (`mvn verify`, `mvn sonar:sonar`) |

#### Utilidades generales

| Herramienta | Instalación | Usado por |
|---|---|---|
| **curl** | `apt install curl` (generalmente preinstalado) | Health checks, descarga de binarios, API calls a Gitea/SonarQube |
| **jq** | `apt install jq` | Parseo de JSON en scripts (tokens SonarQube, outputs Terraform) |
| **yq** | Binario desde GitHub releases | `setup-cicd-pipeline.sh` — manipula archivos YAML de Helm values |
| **git** | `apt install git` | Operaciones de repositorio en scripts CI/CD |
| **python3** | `apt install python3` | Scripts auxiliares de procesamiento |
| **psql** (opcional) | `apt install postgresql-client` | `init-dev-environment.sh` — verifica conexión a RDS emulado en floci |
| **mongosh** (opcional) | Repositorio oficial MongoDB | `init-dev-environment.sh` — verifica conexión a MongoDB |

### Kubernetes (K3s nativo)

| # | Componente | Método |
|---|---|---|
| 9 | **K3s** | `curl -sfL https://get.k3s.io | sh -` — instala K3s directamente, sin Docker wrapper |
| 10 | **ArgoCD** | `helm install argocd argo/argo-cd` sobre K3s |
| 11 | **argocd-bootstrap** | `helm install argocd-bootstrap ./argocd-bootstrap` — chart propio con AppProject, ApplicationSet, repo-credentials, jenkins-agent-rbac |
| 12 | **Prometheus + Grafana + Alertmanager** | `helm install kube-prometheus-stack` sobre K3s |
| 13 | **Jaeger** | `helm install jaeger` sobre K3s |
| 14 | **OTEL Collector** | `kubectl apply` del Deployment + ConfigMap sobre K3s |
| 15 | **Loki + Fluent Bit** | `helm install loki` + `helm install fluent-bit` sobre K3s |

---

## Resumen de cambios por capa

```
ANTES (local)                          DESPUÉS (VPS Ubuntu Server 24.04 LTS)
─────────────────────────────────────  ──────────────────────────────────────────
Docker container: floci              → Docker container: floci (se mantiene — 13 MiB idle)
                                         gestionado con floci CLI (floci start/stop/status)
                                         (ya no levanta contenedor interno para RDS)
RDS emulado por floci (contenedor)   → Servicio systemd: postgresql (apt, nativo en VPS)
                                         bases de datos creadas con psql directamente
Docker container: mongo:7            → Servicio systemd: mongod (apt)
Docker container: apache/kafka:3.7   → Servicio systemd: kafka (binario KRaft)
Docker container: gitea/gitea:1.22   → Servicio systemd: gitea (binario) + registry OCI
Docker container: sonarqube:lts      → Servicio systemd: sonarqube (zip)
Docker container: jenkins:latest     → Servicio systemd: jenkins (apt)
Docker container: wiremock:3.9       → Servicio systemd: wiremock (jar)
Docker container: lra-coordinator    → Servicio systemd: lra-coordinator (jar)
Frontend → Vercel (Terraform)        → Pod K3s: Deployment + Service + Ingress (Traefik)
                                         imagen construida por Jenkins → Gitea registry → ArgoCD
K3d (K3s en Docker)                  → K3s nativo (sin Docker wrapper)
  └─ pods Helm: ArgoCD               →   └─ pods Helm: ArgoCD (igual)
  └─ pods Helm: Prometheus/Grafana   →   └─ pods Helm: Prometheus/Grafana (igual)
  └─ pods Helm: Jaeger               →   └─ pods Helm: Jaeger (igual)
  └─ pods Helm: OTEL Collector       →   └─ pods Helm: OTEL Collector (igual)
  └─ pods Helm: Loki + Fluent Bit    →   └─ pods Helm: Loki + Fluent Bit (igual)
  └─ (nuevo) pod: frontend           →   └─ pod: frontend (Next.js, Ingress Traefik)

Resultado: de 8 contenedores Docker → 1 contenedor Docker (floci)
           + 7 servicios systemd nativos + K3s nativo + frontend en pod K3s
           Todo dentro del VPS — sin dependencias de servicios cloud externos (Vercel)
```

---

## Requisitos del VPS

| Recurso | Valor |
|---|---|
| **CPU** | 8 vCPU |
| **RAM** | 16 GB |
| **Disco** | 120 GB SSD |
| **OS** | Ubuntu Server **24.04 LTS** (instalación minimal) |
| **Red** | IP pública fija o dominio — acceso remoto a Gitea, Jenkins, SonarQube |

> **Por qué 24.04 y no 26.04:** todos los repos oficiales de las herramientas del framework (MongoDB 7, Jenkins, Java 17/21) publican paquetes verificados para `noble` (24.04). 26.04 es demasiado reciente y algunos repos aún no tienen paquetes estables para esa base. La diferencia de RAM entre versiones del OS es ~50 MB — irrelevante.

---

## Ventajas de la migración

- **Elimina la carga en PC local**: los contenedores y servicios corren en el VPS, no en la máquina de desarrollo.
- **K3s nativo es más liviano**: K3d agrega una capa Docker innecesaria; K3s directo consume ~30% menos RAM.
- **Persistencia simplificada**: los datos de MongoDB, Gitea y SonarQube viven en el filesystem del VPS, sin volúmenes Docker.
- **Acceso remoto natural**: Jenkins, SonarQube y Gitea quedan accesibles desde cualquier equipo de desarrollo vía IP/dominio del VPS.

---

## Módulos Terraform: qué se elimina y qué se conserva

### Módulos que se eliminan completamente (5)

| # | Módulo | Reemplazado por |
|---|---|---|
| 1 | `terraform/frontend/` (completo) | Pod K3s + Ingress Traefik — provider `vercel/vercel` desaparece |
| 2 | `terraform/backend/modules/ecr` | Gitea Package Registry (OCI nativo) |
| 3 | `terraform/backend/modules/rds` | PostgreSQL nativo en VPS como servicio systemd |
| 4 | `terraform/backend/modules/jenkins` | Jenkins nativo en VPS como servicio systemd |
| 5 | `terraform/backend/modules/argocd` | `helm install argo-cd` (CLI) + chart `argocd-bootstrap` propio con AppProject, ApplicationSet, repo-credentials y jenkins-agent-rbac |

### Módulos que se conservan sin cambios

| Módulo | Razón |
|---|---|
| `terraform/backend/modules/cognito` | Autenticación JWT — lo emula floci en proceso (sin contenedor Docker) |
| `terraform/backend/modules/api-gateway` | API Gateway HTTP — lo emula floci en proceso |
| `terraform/backend/modules/secrets-manager` | Variables de entorno de microservicios — lo emula floci en proceso |
| `terraform/backend/modules/reporting-lambdas` | Reportería — S3 + EventBridge via floci en proceso; Lambda usa Docker interno de floci |

### Módulos que se modifican parcialmente

#### `terraform/backend/modules/iam`
Recursos que **desaparecen**:
- `aws_iam_policy.ecr_pull` — ya no hay ECR
- `aws_iam_role_policy_attachment.task_ecr` — idem

Recursos que **se conservan**:
- `aws_iam_role.ecs_task_execution` + `aws_iam_role.ecs_task` — aún referenciados por `secrets-manager` y `api-gateway`
- `aws_iam_policy.secrets_read` + `aws_iam_role_policy_attachment.task_secrets`

#### `terraform/backend/modules/msk`
Ya estaba **desactivado en dev** (`enabled = false` — floci lo dejaba en estado CREATING indefinidamente). El módulo se puede eliminar del `dev/main.tf` directamente. Se conserva para staging/prod (AWS MSK real).

#### `terraform/backend/modules/mongodb`
El módulo gestiona MongoDB en EC2+EBS para staging/prod. **No aplica a dev** (MongoDB es nativo en el VPS). Se conserva para staging/prod sin cambios.

#### `terraform/backend/modules/eks`
**Nunca estuvo en dev** — el `dev/main.tf` nunca llama a `module "eks"` (el propio script lo comenta explícitamente: K3d/K3s reemplaza a EKS en dev). No hay nada que eliminar en dev. El módulo se conserva para staging/prod (AWS EKS real) sin cambios.

---

### Impacto en `environments/dev/main.tf`

| Bloque actual | Acción |
|---|---|
| `module "ecr"` | **Eliminar** |
| `module "rds"` | **Eliminar** |
| `module "msk"` (`enabled = false`) | **Eliminar** — ya era dead code |
| `module "jenkins"` | No existe en dev (comentado desde el origen) — sin cambios |
| `local.dev_registry = "k3d-...-registry:5100"` | **Actualizar** a URL del Gitea Package Registry |
| `local.kafka_bootstrap_brokers` | **Actualizar** a `localhost:9092` (Kafka nativo en VPS) |
| `module "iam"` | **Modificar** — eliminar referencias a `ecr_pull` |
| `module "cognito"` | Sin cambios |
| `module "api_gateway"` | Sin cambios |
| `module "secrets_manager"` | Sin cambios |
| `module "argocd"` | **Eliminar** — ArgoCD se instala con `helm install` directo en el VPS |

### Impacto en `environments/dev/outputs.tf`

| Output actual | Acción |
|---|---|
| `ecr_repository_urls` | **Eliminar** |
| `ecr_registry` | **Reemplazar** por `gitea_registry_url` apuntando al Gitea Package Registry |
| `rds_endpoint`, `rds_port`, `rds_db_name`, `rds_arn` | **Eliminar** — reemplazar por documentación de conexión a PostgreSQL nativo (`localhost:5432`) |

### Impacto en `environments/dev/providers.tf`

Endpoints del provider `aws` que se pueden eliminar:
- `rds = "http://localhost:4566"` → PostgreSQL nativo, no pasa por floci
- `ecr = "http://localhost:4566"` → Gitea registry
- `kafka = "http://localhost:4566"` → Kafka nativo
- `eks = "http://localhost:4566"` → K3s nativo (kubeconfig directo)
- `elasticloadbalancing` / `elasticloadbalancingv2` → solo los usaba el módulo jenkins (eliminado)
- `autoscaling` → solo lo usaban jenkins y mongodb EC2 (no aplican en dev)

Endpoints que **se conservan** (floci los sigue emulando en proceso):
- `s3`, `iam`, `sts`, `cognitoidp`, `apigateway`, `apigatewayv2`, `secretsmanager`, `lambda`, `events`, `ssm`, `cloudwatchlogs`

### Impacto en `modules/jenkins/variables.tf` y `user_data`

Las variables relacionadas con Vercel desaparecen en todos los entornos:
- `vercel_token`, `vercel_org_id`, `vercel_project_id`
- `ECR_REGISTRY` → reemplazado por la URL del Gitea Package Registry
- `IAM policy jenkins_agent`: eliminar los `Sid: ECRAuth` y `Sid: ECRPushPull` — los agentes ya no hacen push a ECR

---

## Próximos pasos sugeridos

1. Provisionar el VPS (Ubuntu Server 24.04 LTS minimal, 16 GB RAM, 8 vCPU, 120 GB SSD).
2. Instalar prerequisitos del sistema (Docker, AWS CLI, kubectl, helm, terraform, Java 21, Maven, curl, jq, yq, git, python3).
3. Instalar floci CLI (`curl -fsSL https://floci.io/install.sh | sh`) y levantar floci.
4. Crear script `vps-setup.sh` que instale cada herramienta como servicio systemd (MongoDB, Kafka, Gitea, SonarQube, Jenkins, WireMock, LRA).
5. Instalar K3s nativo (`curl -sfL https://get.k3s.io | sh -`).
6. Redesplegar el stack de observabilidad (Prometheus, Grafana, Jaeger, OTEL, Loki, Fluent Bit, ArgoCD) vía Helm sobre K3s.
7. **Eliminar** el módulo Terraform `terraform/frontend/` (provider Vercel).
8. **Eliminar** el módulo Terraform `terraform/backend/modules/ecr` y la política `ecr_pull` del módulo `iam`.
9. **Eliminar** el módulo Terraform `terraform/backend/modules/rds`.
10. Instalar PostgreSQL 16 en el VPS (`apt install postgresql`) y crear las bases de datos de cada microservicio con `psql`.
11. Habilitar el **Gitea Package Registry** (OCI/Docker) — usado como registry para frontend y todos los microservicios.
12. Crear `Secret` en K3s con credenciales de Gitea (`imagePullSecrets`) para que los pods puedan hacer pull de imágenes.
13. Crear `Dockerfile` para el frontend (Next.js standalone) y Helm chart con `Deployment` + `Service` + `Ingress` (Traefik).
14. Adaptar jobs Jenkins: reemplazar push a ECR por push a Gitea registry en todos los servicios (frontend + microservicios).
15. Adaptar `base-infrastructure-builder.sh`: reemplazar `docker run` de cada servicio por verificación de estado systemd remoto.
16. Adaptar `setup-cicd-pipeline.sh`: apuntar Jenkins y ArgoCD a la IP/dominio del VPS.
