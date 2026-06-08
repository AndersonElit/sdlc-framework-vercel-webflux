# SDLC Framework — Automatización del Ciclo de Vida de Desarrollo

Framework basado en **Claude Code** que automatiza el SDLC de extremo a extremo: a partir de una descripción de proyecto genera, etapa por etapa, los documentos profesionales de planeación, requerimientos, diseño estratégico, diseño técnico y plan de implementación, además de los artefactos ejecutables (Terraform, OpenAPI, modelo de datos, diagramas C4, scaffolding y pipeline CI/CD).

Cada etapa consume la salida de la etapa anterior, de modo que el conocimiento del proyecto se propaga y enriquece a lo largo de todo el pipeline.

---

## Visión General del Pipeline

```
  Formato de entrada                 Skill                         Salida
  ─────────────────                  ─────                         ──────
1 input-template.md ──────────────►  (lo diligencias tú)  ───────► requerimiento/<proyecto>.md
2 requerimiento/<proyecto>.md ─────► /plan-pid            ───────► docs/planning/PID-<proyecto>.md
3 PID ─────────────────────────────► /requirements-srs    ──────► docs/requirements/SRS-<proyecto>.md
4 input-adc-template.md ───────────► (lo diligencias tú)  ───────► docs/planning/ADC-<proyecto>.md
5 SRS + ADC ───────────────────────► /strategic-design-sdd ─────► docs/strategic-design/SDD-<proyecto>-{domain,security,architecture}.md
6 Strategic Design ────────────────► /technical-design-sdd ──────► docs/design/  (system, design, infrastructure + OpenAPI, schema, C4)
7 Diseño Técnico ──────────────────► /development-plan     ──────► docs/development/  (roadmap + planes por etapa)
```

> **Importante — orden del ADC:** diligencia **primero** `.claude/formatos/input-adc-template.md` (paso 4) y **luego** invoca `/strategic-design-sdd` (paso 5), pasándolo como segundo argumento. El _Architectural Decision Context_ es entrada del **diseño estratégico**; no se pasa a `/technical-design-sdd`, que solo lee `docs/strategic-design/`.

---

## Prerrequisitos

- **Claude Code** instalado y ejecutándose desde la raíz de este repositorio (las skills viven en `.claude/skills/`).
- Para la **etapa de implementación** (artefactos generados por `/development-plan`): Terraform, kubectl, Java 21, Node.js, Python 3 en el host local. Los servicios del framework (MongoDB, Kafka, Gitea, SonarQube, Jenkins, WireMock, LRA Coordinator, floci, K3s) corren en el **VPS Ubuntu 26.04 LTS** creado con `qemu-vps.sh` e instalados con `vps-setup.sh`. No se necesitan para generar la documentación, solo para ejecutar los planes.

---

## Estructura del Repositorio

```
.
├── .claude/
│   ├── formatos/                 # Plantillas de entrada que diligencias tú
│   │   ├── input-template.md     # Entrada para /plan-pid
│   │   └── input-adc-template.md # Entrada (ADC) para /strategic-design-sdd
│   ├── skills/                   # Las 5 skills del pipeline
│   ├── scripts/                  # Scripts de implementación (infra, scaffold, CI/CD…)
│   └── templates/                # Scaffolders (Maven hexagonal, Next.js, Scala/Spark reportería, lambdas de formato)
├── requerimiento/                # Aquí guardas el formato de entrada diligenciado
├── PLAN-VPS-LOCAL-QEMU.md        # Guía detallada de creación del VPS con QEMU/KVM
├── PLAN-VPS-MIGRATION.md         # Decisiones arquitectónicas: Docker local → servicios systemd en VPS
└── docs/                         # Salida generada por las skills
    ├── planning/                 # PID + ADC
    ├── requirements/             # SRS
    ├── strategic-design/         # SDD estratégico
    ├── design/                   # SDD técnico + artefactos
    └── development/              # Planes de desarrollo
```

---

## Flujo de Uso Paso a Paso

### Paso 1 — Diligenciar el formato de entrada

Copia `.claude/formatos/input-template.md`, complétalo con la información de tu proyecto (los campos marcados con `*` son obligatorios) y guarda el resultado en el directorio **`requerimiento/`**.

```bash
cp .claude/formatos/input-template.md requerimiento/<proyecto>.md
# edita requerimiento/<proyecto>.md con los datos del proyecto
```

Campos clave: identificación del proyecto, problema de negocio, objetivos, alcance, stakeholders, requerimientos de alto nivel, supuestos y restricciones, presupuesto y riesgos.

### Paso 2 — Generar el PID (Planeación)

Invoca `/plan-pid` pasándole el contenido del documento diligenciado en el paso anterior.

```
/plan-pid <pega el contenido de requerimiento/<proyecto>.md>
```

**Salida:** `docs/planning/PID-<proyecto>.md` — Project Initiation Document (resumen ejecutivo, alcance, viabilidad, riesgos, cronograma y costos de alto nivel).

### Paso 3 — Generar el SRS (Análisis de Requerimientos)

Invoca `/requirements-srs`. Sin argumentos busca el PID en `docs/planning/`; o pásale la ruta explícita.

```
/requirements-srs docs/planning/PID-<proyecto>.md
```

**Salida:** `docs/requirements/SRS-<proyecto>.md` — Software Requirements Specification (requerimientos funcionales RF-xxx, no funcionales RNF-xxx, reglas de negocio, casos de uso y criterios de aceptación).

### Paso 4 — Diligenciar el ADC (Architectural Decision Context)

Copia `.claude/formatos/input-adc-template.md` y complétalo apoyándote en el SRS. Define el stack permitido/excluido, modelo de despliegue, estilo arquitectónico, atributos de calidad y SLAs, compliance, integraciones, capacidad del equipo y decisiones ya tomadas. Guárdalo en `docs/planning/`.

```bash
cp .claude/formatos/input-adc-template.md docs/planning/ADC-<proyecto>.md
# edita docs/planning/ADC-<proyecto>.md
```

El ADC tiene **precedencia** sobre lo inferido del SRS: sus decisiones se tratan como restricciones del proyecto, no como sugerencias.

### Paso 5 — Generar el Strategic Design (Pre-Diseño)

Invoca `/strategic-design-sdd` con el SRS y, opcionalmente, el ADC como segundo argumento.

```
/strategic-design-sdd docs/requirements/SRS-<proyecto>.md docs/planning/ADC-<proyecto>.md
```

**Salida (tres documentos en `docs/strategic-design/`):**
- `SDD-<proyecto>-domain.md` — dominio, bounded contexts, lenguaje ubicuo, eventos y escenarios BDD.
- `SDD-<proyecto>-security.md` — modelo de seguridad, threat modeling (STRIDE) y trust boundaries.
- `SDD-<proyecto>-architecture.md` — drivers arquitectónicos, decisiones estratégicas (DS-xxx) y tradeoffs.

### Paso 6 — Generar el Diseño Técnico (Diseño)

Invoca `/technical-design-sdd`. Sin argumentos lee toda la carpeta `docs/strategic-design/`.

```
/technical-design-sdd docs/strategic-design/
```

**Salida (en `docs/design/`):**
- `SDD-<proyecto>-system.md` — arquitectura, stack y componentes.
- `SDD-<proyecto>-design.md` — APIs, persistencia, flujos y seguridad técnica.
- `SDD-<proyecto>-infrastructure.md` — infraestructura, observabilidad, ADRs y riesgos.
- `diagrams/SDD-<proyecto>-c4-context.mmd` y `c4-container.mmd` — diagramas C4 (Mermaid).
- `api/SDD-<proyecto>-openapi.yaml` — especificación OpenAPI 3.0.
- `database/SDD-<proyecto>-schema.sql` y/o `collections.js` — modelo de datos.

### Paso 7 — Generar el Plan de Desarrollo (Implementación)

Invoca `/development-plan`. Sin argumentos lee toda la carpeta `docs/design/`.

```
/development-plan docs/design/
```

**Salida (en `docs/development/`):** un roadmap maestro más planes detallados y secuenciales por etapa, todos bajo **TDD (Red-Green-Refactor)**:

| Documento | Contenido |
|-----------|-----------|
| `DEV-<proyecto>-roadmap.md` | Índice maestro, prerrequisitos, secuencia, mapa de microservicios y features |
| `DEV-<proyecto>-00-infrastructure.md` | Infraestructura VPS (Terraform + floci + K3s nativo) |
| `DEV-<proyecto>-01-databases.md` | Bases de datos y migraciones (PostgreSQL 16 y MongoDB 7 nativos en VPS) |
| `DEV-<proyecto>-02-scaffold.md` | Scaffolding de proyectos |
| `DEV-<proyecto>-02b-cicd.md` | Pipeline CI/CD (Jenkins systemd + ArgoCD en K3s) |
| `DEV-<proyecto>-03-ms-<servicio>.md` | Un documento por microservicio (capas hexagonales) |
| `DEV-<proyecto>-04-fe-<feature>.md` | Un documento por feature frontend (Next.js, pod K3s) |
| `DEV-<proyecto>-05-tests.md` | Integración, E2E, estrés y carga |

---

## Resumen: Entradas y Salidas por Etapa

| # | Etapa SDLC | Acción | Entrada | Salida |
|---|-----------|--------|---------|--------|
| 1 | — | Diligenciar `input-template.md` | Datos del proyecto | `requerimiento/<proyecto>.md` |
| 2 | Planeación | `/plan-pid` | Documento del paso 1 | `docs/planning/PID-<proyecto>.md` |
| 3 | Análisis de Requerimientos | `/requirements-srs` | PID | `docs/requirements/SRS-<proyecto>.md` |
| 4 | — | Diligenciar `input-adc-template.md` | SRS | `docs/planning/ADC-<proyecto>.md` |
| 5 | Pre-Diseño | `/strategic-design-sdd` | SRS + ADC | `docs/strategic-design/SDD-<proyecto>-{domain,security,architecture}.md` |
| 6 | Diseño | `/technical-design-sdd` | Strategic Design | `docs/design/` (system, design, infrastructure + OpenAPI, schema, C4) |
| 7 | Implementación | `/development-plan` | Diseño Técnico | `docs/development/` (roadmap + planes por etapa) |

---

## Implementación: Scripts de Apoyo

Los planes generados en el paso 7 referencian scripts ejecutables en `.claude/scripts/` que automatizan la etapa de implementación en un ambiente **VPS-first (floci + K3s nativo)**. Los servicios del framework corren como unidades **systemd** en el VPS Ubuntu 26.04 LTS creado con `qemu-vps.sh`.

### Scripts de gestión del VPS

| Script | Propósito | Parámetros clave |
|--------|-----------|-----------------|
| `qemu-vps.sh` | Crea y gestiona la VM QEMU/KVM: `create`, `setup`, `snapshot`, `status`, `delete` | `--vm-ip`, `--vcpus`, `--ram`, `--disksize` |
| `vps-setup.sh` | Instala servicios systemd en el VPS vía SSH: `prereqs`, `services`, `floci`, `k3s`, `all` | `--vm-ip`, `--project` |

### Scripts de inicialización del proyecto

| Script | Propósito | Parámetros clave |
|--------|-----------|-----------------|
| `base-infrastructure-builder.sh` | Genera el árbol Terraform multi-ambiente, verifica servicios en VPS vía SSH, descarga kubeconfig K3s, genera Helm chart del frontend (K3s + Traefik) | `-P`, `--vps-ip` |
| `init-dev-environment.sh` | Terraform apply sobre floci en VPS, verifica K3s y ArgoCD, muestra tabla de endpoints del VPS | `-P`, `--vps-ip` |
| `init-databases.sh` | Crea usuario y bases en PostgreSQL 16 nativo y MongoDB 7 nativo del VPS | `-P`, `--vps-ip`, `-p`, `-m`, `-u`, `-w` |
| `run-liquibase-migrations.sh` | Aplica changelogs Liquibase contra PostgreSQL nativo del VPS; `--gitea-clone` clona el repo `<proyecto>-migrations` desde Gitea automáticamente; `--db-dir` acepta un clon local | `-P`, `--vps-ip`, `-p`, `-u`, `-w`, `[--gitea-clone\|--db-dir]` |

### Scripts de scaffold y CI/CD

| Script | Propósito | Parámetros clave |
|--------|-----------|-----------------|
| `scaffold-all-services.sh` | Scaffolding de microservicios (Maven hexagonal) y frontend (Next.js), changelogs Liquibase, crea repo `<proyecto>-migrations` en Gitea del VPS y hace push del schema inicial, secrets | `-P`, `--vps-ip`, `--backend`, `--frontend`, `-p`, `-m`, `-u`, `-w`, `[--migrations-repo]` |
| `jenkins-shared-library-builder.sh` | Genera la Shared Library de Jenkins (vars/, pods, JCasC, Dockerfile del controller) | `-P`, `--vps-ip`, `-o` |
| `setup-cicd-pipeline.sh` | Configura el pipeline CI/CD: shared library, imagen controller → Gitea registry, bootstrap K3s, jobs multibranch, webhooks Gitea, ArgoCD bootstrap | `-P`, `-S`, `--vps-ip`, `-F` |
| `setup-observability.sh` | Instala stack de observabilidad (Prometheus, Grafana, Jaeger, OTEL, Loki, Fluent Bit) en K3s del VPS via Helm | `-P` |
| `create-all-secrets-dev.sh` | Crea/actualiza secrets de cada servicio en floci del VPS con endpoints nativos (VPS_IP:*) | `-P`, `--vps-ip`, `-p`, `-m`, `-u`, `-w` |
| `compile-services.sh` / `verify-frontend.sh` | Verificación de compilación backend (Maven) y frontend (TypeScript/lint) | — |

> **Dev:** K3s nativo en VPS — EKS se reserva para `staging`/`prod`. El frontend se despliega como pod K3s con Ingress Traefik, imagen publicada en el **Gitea Package Registry** del VPS (`VPS_IP:3000/<org>`). Jenkins corre como **servicio systemd** en el VPS (no como contenedor Docker local).

### Templates de scaffolding

Los scaffolders Python en `.claude/templates/` leen la variable de entorno **`VPS_IP`** para configurar los endpoints en los artefactos que generan (secret scripts, `.env`, JDBC URLs, Gitea remote URL):

```bash
VPS_IP=192.168.122.50 bash .claude/scripts/scaffold-all-services.sh \
  -P miproyecto --vps-ip 192.168.122.50 \
  --backend seguridad-service:postgres:none:8081 \
  --backend clientes-service:postgres:kafka-producer:8082 \
  -p miproyecto_dev -m miproyecto_audit \
  -u appuser -w secret123 \
  --frontend miproyecto-web
```

---

## VPS Local con QEMU/KVM

El framework requiere un VPS Ubuntu 26.04 LTS donde los servicios corren como unidades systemd. Se crea localmente con QEMU/KVM y se configura en dos pasos: `qemu-vps.sh` (gestión de la VM) y `vps-setup.sh` (instalación de servicios).

### Paso 1 — Prerrequisitos del host (una sola vez)

```bash
# 1. Verificar soporte de virtualización en el CPU (debe ser > 0)
egrep -c '(vmx|svm)' /proc/cpuinfo

# 2. Instalar QEMU/KVM y herramientas de gestión
sudo apt update
sudo apt install -y qemu-system-x86 qemu-utils libvirt-daemon-system \
  libvirt-clients virtinst bridge-utils cpu-checker iptables-persistent
sudo kvm-ok
sudo usermod -aG libvirt,kvm $USER
newgrp libvirt

# 3. Descargar ISO Ubuntu 26.04 LTS
mkdir -p ~/vms/iso
wget -P ~/vms/iso https://releases.ubuntu.com/26.04/ubuntu-26.04-live-server-amd64.iso
wget -P ~/vms/iso https://releases.ubuntu.com/26.04/SHA256SUMS
cd ~/vms/iso && sha256sum -c SHA256SUMS --ignore-missing
```

### Paso 2 — Crear y configurar la VM (`qemu-vps.sh`)

```bash
# Crear disco + VM (ajustar según hardware disponible)
.claude/scripts/qemu-vps.sh create --vcpus 8 --ram 16384 --disksize 120G

# Instalar Ubuntu en la consola serial (ver PLAN-VPS-LOCAL-QEMU.md § Paso 3)
virsh console sdlc-vps
# Seguir el instalador: idioma, red, usuario "ubuntu", instalar OpenSSH.
# Al terminar: sudo poweroff  →  Ctrl+] para salir.

# Ver IP asignada
virsh start sdlc-vps
.claude/scripts/qemu-vps.sh status

# Configuración post-instalación OCI-compatible (SSH key-only, sudo NOPASSWD,
# hostname, UTC, NTP, UFW, cloud-init NoCloud, sysctl vm.max_map_count)
.claude/scripts/qemu-vps.sh setup --vm-ip 192.168.122.50

# Snapshot base antes de instalar servicios
.claude/scripts/qemu-vps.sh snapshot
# Restaurar en el futuro: virsh snapshot-revert sdlc-vps base-oci-config
```

### Paso 3 — Instalar servicios en el VPS (`vps-setup.sh`)

```bash
VPS_IP=192.168.122.50

# Instalar todo de una vez (prereqs → services → floci → k3s)
.claude/scripts/vps-setup.sh all --vm-ip $VPS_IP --project miproyecto

# O en pasos individuales:
.claude/scripts/vps-setup.sh prereqs  --vm-ip $VPS_IP   # Java 21, kubectl, helm, terraform, AWS CLI, Maven, yq
.claude/scripts/vps-setup.sh services --vm-ip $VPS_IP   # MongoDB, Kafka, Gitea, SonarQube, Jenkins, WireMock, LRA
.claude/scripts/vps-setup.sh floci    --vm-ip $VPS_IP   # floci CLI + contenedor floci/floci:latest (Docker)
.claude/scripts/vps-setup.sh k3s      --vm-ip $VPS_IP   # K3s nativo + ArgoCD via Helm + kubeconfig descargado
```

`vps-setup.sh k3s` descarga el kubeconfig al host en `~/.kube/config-k3s-vps`.

### Paso 4 — Verificar el VPS

```bash
.claude/scripts/vps-setup.sh status --vm-ip $VPS_IP
```

### Referencia `qemu-vps.sh`

| Comando | Descripción |
|---------|-------------|
| `create` | Crea el disco qcow2 y define la VM en libvirt |
| `setup` | Configuración post-instalación OCI-compatible + port-forwarding iptables |
| `snapshot` | Crea el snapshot `base-oci-config` |
| `status` | Muestra estado, IP, snapshots y tamaño del disco |
| `delete` | Destruye la VM, snapshots, definición libvirt, disco y reglas iptables |

| Opción | Por defecto | Descripción |
|--------|-------------|-------------|
| `--vcpus N` | `4` | Número de vCPUs |
| `--ram N` | `8192` | RAM en MB |
| `--disksize S` | `60G` | Tamaño del disco (p. ej. `40G`, `120G`) |
| `--name NAME` | `sdlc-vps` | Nombre de la VM en libvirt |
| `--vm-ip IP` | _(autodetectado)_ | IP de la VM (requerido en `setup`; opcional en `delete`) |
| `--ssh-key FILE` | `~/.ssh/id_ed25519.pub` | Ruta a la clave SSH pública |
| `--force` | `false` | Omite confirmación interactiva (solo en `delete`) |

### Referencia `vps-setup.sh`

| Comando | Servicios instalados |
|---------|---------------------|
| `prereqs` | Java 21 LTS, Maven 3.9, kubectl, Helm, Terraform, AWS CLI v2, yq, git, curl, jq, python3 |
| `services` | Docker, MongoDB 7 (`mongod`), Kafka 3.7 KRaft (`kafka`), Gitea 1.22 (`gitea`), SonarQube LTS (`sonarqube`), Jenkins LTS (`jenkins`), WireMock 3.9 (`wiremock`), Narayana LRA Coordinator (`lra-coordinator`) |
| `floci` | floci CLI + contenedor `floci/floci:latest` (Docker requerido por floci) |
| `k3s` | K3s nativo + ArgoCD via Helm (NodePort `VPS_IP:30080`) + kubeconfig descargado al host |
| `all` | Ejecuta `prereqs` → `services` → `floci` → `k3s` en orden |
| `status` | Muestra estado de todos los servicios systemd + pods K3s |

### Endpoints del VPS por servicio

| Servicio | Endpoint | Puerto |
|----------|----------|--------|
| SSH | `VPS_IP` | 22 |
| floci (AWS emulado) | `http://VPS_IP:4566` | 4566 |
| PostgreSQL 16 (nativo) | `VPS_IP` | 5432 |
| MongoDB 7 (nativo) | `mongodb://VPS_IP` | 27017 |
| Kafka (KRaft, externo) | `VPS_IP` | 29092 |
| Kafka (KRaft, K3s pods) | `VPS_IP` | 9092 |
| Gitea UI / API | `http://VPS_IP:3000` | 3000 |
| Gitea Package Registry | `http://VPS_IP:3000/<org>` | 3000 |
| Gitea SSH | `VPS_IP` | 2222 |
| SonarQube | `http://VPS_IP:9000` | 9000 |
| Jenkins | `http://VPS_IP:8080` | 8080 |
| LRA Coordinator | `http://VPS_IP:50000` | 50000 |
| WireMock | `http://VPS_IP:9999` | 9999 |
| K3s API | `https://VPS_IP:6443` | 6443 |
| ArgoCD UI | `http://VPS_IP:30080` | 30080 |

---

## Integración con Sistemas Externos (Apache Camel) y Transacciones Distribuidas (Saga)

El framework soporta, de forma **opt-in y trazable end-to-end**, dos capacidades para arquitecturas de microservicios:

- **Capa de integración con Apache Camel** concentrada en un microservicio dedicado **`integration-service`** (ACL / mediación EAI): consumo de APIs y sistemas externos, traducción de protocolos, reintentos y circuit breaker (Resilience4j). Los servicios de dominio no hablan con el exterior: consumen `integration-service`.
- **Patrón Saga (orquestación)** alojado en el mismo `integration-service` (Camel Saga EIP + coordinador **Narayana LRA**). Los servicios de dominio actúan como **participantes**: publican eventos vía **Transactional Outbox** (atómico con el cambio de BD) y exponen **compensaciones idempotentes**.

Se propaga por todo el pipeline: el ADC captura sistemas externos y estrategia transaccional → el Strategic Design los modela (context map/ACL, `DS-xxx`) → el Diseño Técnico genera el contenedor `integration-service` en el C4, los flujos de saga con compensaciones, los endpoints de compensación en OpenAPI y las tablas `outbox`/`saga_instance` en el `schema.sql` → el Plan de Desarrollo emite el documento del `integration-service` y las secciones de participante, todo bajo **TDD** (rutas Camel con WireMock, saga compensada, outbox con Testcontainers).

**Generación de código (etapa de implementación):**

| Componente | Cómo se genera |
|------------|----------------|
| `integration-service` (Camel + saga orquestador) | Scaffolder dedicado `.claude/templates/integration_service_scaffold.py` |
| Outbox + compensaciones en participantes | Banderas `--outbox` / `--saga-participant` de `maven_hexagonal_scaffold.py` |
| Orquestación | `scaffold-all-services.sh` con `--integration-service "sis=BC-XX,..."`, `--saga-flows f1,f2`, `--outbox <svc>`, `--saga-participant <svc>` |
| Infraestructura VPS | `vps-setup.sh services` instala el coordinador Narayana LRA (`lra-coordinator.service`, VPS:50000) y WireMock (`wiremock.service`, VPS:9999) como servicios systemd. `base-infrastructure-builder.sh` verifica su estado via SSH (omitir con `ENABLE_SAGA=0`) |
| Secretos | `create-all-secrets-dev.sh` detecta el `integration-service` y añade `LRA_COORDINATOR_URL=http://VPS_IP:50000/lra-coordinator` y `EXT_*_BASE_URL=http://VPS_IP:9999/<sistema>` |
| CI/CD | Stage `Contract Tests` (WireMock) en el Jenkinsfile generado, activo solo para el `integration-service` |

> Detalle completo y decisiones arquitectónicas: [PLAN-integracion-camel-saga.md](PLAN-integracion-camel-saga.md).

---

## Reportería (ETL Apache Spark + Generación de Formatos Serverless)

El framework soporta, de forma **opt-in y trazable end-to-end**, un subsistema de reportería para producir reportes (PDF/XLS/CSV) a partir de datos operacionales:

- **ETL por lotes con Apache Spark** en dos microservicios Scala (arquitectura hexagonal, generados con `scala_hexagonal_scaffold.py`): **`report-extraction-service` (MS1)** extrae del **read model CQRS** (MongoDB nativo en VPS; o JDBC PostgreSQL nativo en proyectos sin CQRS), **valida contra un esquema declarado** y materializa parquet crudo en S3 (floci en dev), publicando `report.extracted`; **`report-processing-service` (MS2)** transforma por **tipo de reporte** (patrón Factory, abierto/cerrado) y produce parquet listo, publicando `report.processed`.
- **Capa de formatos serverless** (AWS Lambda + EventBridge): un _Lambda Kafka Consumer_ enruta por EventBridge (una rule por formato) a las lambdas **PDF/XLS/CSV**, que renderizan a `output/`. En dev corre sobre **floci** (S3/Lambda/EventBridge en `VPS_IP:4566`), con el **mismo Terraform** que en AWS real.

Se propaga por todo el pipeline: el ADC (sección 13) declara tipos de reporte/fuentes/formatos → el Strategic Design añade el bounded context de Reportería y `DS-xxx` → el Diseño Técnico genera los contenedores MS1/MS2 y la malla serverless en el C4, los esquemas parquet y `report_schema_catalog` en el modelo de datos, y los `ADR-xxx` → el Plan de Desarrollo emite los documentos `03-ms-report-extraction-service.md`, `03-ms-report-processing-service.md` y `06-reporting-serverless.md`, todo bajo **TDD**.

**Generación de código (etapa de implementación):**

| Componente | Cómo se genera |
|------------|----------------|
| `report-extraction-service` (MS1, Spark) | `scala_hexagonal_scaffold.py --report-role extraction --source mongo\|jdbc` |
| `report-processing-service` (MS2, Spark) | `scala_hexagonal_scaffold.py --report-role processing --report-types <lista>` (Factory de transformers) |
| Capa serverless de formatos | `report_lambdas_scaffold.py --org <proyecto> --formats pdf,xls,csv` (lambdas + Terraform EventBridge) |
| Orquestación | `scaffold-all-services.sh` con `--report-extraction`, `--report-processing`, `--report-types`, `--report-formats` y `--vps-ip` |
| Infraestructura VPS | `base-infrastructure-builder.sh` crea el bucket S3, los topics `report.*` y el bus EventBridge en floci del VPS (`VPS_IP:4566`). Omitir con `ENABLE_REPORTING=0`; solo serverless con `ENABLE_REPORTING_SERVERLESS=0` |
| Catálogo de esquemas | `init-databases.sh --vps-ip` crea la BD `<prefijo>_reporting` vacía; el schema de `report_schema_catalog` lo aplica Liquibase vía `run-liquibase-migrations.sh --gitea-clone` |
| Secretos | `create-all-secrets-dev.sh --vps-ip` crea el secret `<proyecto>/dev/reporting` (S3/floci `VPS_IP:4566`, Kafka `VPS_IP:29092`, EventBridge) |
| CI/CD | Steps `assembleSparkService` (fat JAR Spark + Kaniko → Gitea registry) y `deployReportingLambdas` (Terraform con `TF_VAR_aws_endpoint_url=http://VPS_IP:4566`) en la shared library |

> Detalle completo y decisiones arquitectónicas: [PLAN-reporteria-spark-etl.md](PLAN-reporteria-spark-etl.md).

---

## Principios del Framework

- **Trazabilidad end-to-end:** cada documento se deriva del anterior; el ADC y las decisiones estratégicas (DS-xxx) actúan como restricciones que se propagan al diseño técnico y a la implementación.
- **Artefactos ejecutables:** el diseño no se queda en prosa — produce OpenAPI, DDL/colecciones, diagramas C4 y scripts de infraestructura reales.
- **TDD obligatorio:** todos los planes de desarrollo exigen el ciclo Red-Green-Refactor por capa (dominio → aplicación → infraestructura → rest-api) y por artefacto frontend.
- **VPS-first:** los servicios del framework corren como unidades systemd en un VPS Ubuntu 26.04 LTS (QEMU/KVM local), eliminando la carga de contenedores en la máquina de desarrollo. K3s reemplaza K3d; Gitea Package Registry reemplaza ECR en dev; PostgreSQL 16 nativo reemplaza RDS/floci; el frontend se despliega en K3s (no en Vercel).
- **Documentos minimalistas y profesionales:** en español técnico, sin relleno, listos para revisión por stakeholders.
