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
- Para la **etapa de implementación** (artefactos generados por `/development-plan`): Docker, Terraform, k3d, kubectl, Java 21, Node.js, Python 3 y el CLI de floci. No se necesitan para generar la documentación, solo para ejecutarla.

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
│   └── templates/                # Scaffolders (Maven hexagonal, Next.js)
├── requerimiento/                # Aquí guardas el formato de entrada diligenciado
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
| `DEV-<proyecto>-00-infrastructure.md` | Infraestructura local (Terraform + floci + K3d) |
| `DEV-<proyecto>-01-databases.md` | Bases de datos y migraciones |
| `DEV-<proyecto>-02-scaffold.md` | Scaffolding de proyectos |
| `DEV-<proyecto>-02b-cicd.md` | Pipeline CI/CD (Jenkins + ArgoCD) |
| `DEV-<proyecto>-03-ms-<servicio>.md` | Un documento por microservicio (capas hexagonales) |
| `DEV-<proyecto>-04-fe-<feature>.md` | Un documento por feature frontend (Next.js) |
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

Los planes generados en el paso 7 referencian scripts ejecutables en `.claude/scripts/` que automatizan la etapa de implementación en un ambiente **local-first (floci + K3d)**:

| Script | Propósito |
|--------|-----------|
| `base-infrastructure-builder.sh` | Genera el árbol Terraform multi-ambiente y levanta la infraestructura base (floci, MongoDB, Kafka, Gitea, SonarQube, K3d + ArgoCD) |
| `init-dev-environment.sh` | Inicializa el ambiente dev (Terraform apply, verificación de contenedores y cluster) |
| `init-databases.sh` | Crea usuario/bases PostgreSQL y MongoDB y aplica el esquema |
| `scaffold-all-services.sh` | Scaffolding de microservicios (Maven hexagonal) y frontend (Next.js), migraciones Flyway, secrets y push a Gitea |
| `setup-cicd-pipeline.sh` | Configura el pipeline CI/CD completo (shared library, Jenkins, jobs, webhooks, ArgoCD) |
| `compile-services.sh` / `verify-frontend.sh` | Verificación de compilación backend y frontend |
| `create-all-secrets-dev.sh` | Crea los secrets de cada servicio en floci |

> En `dev` el cluster de Kubernetes es **K3d** (real, sobre `floci-net`); EKS se reserva para `staging`/`prod`. El frontend se despliega a **Vercel**.

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
| Outbox + compensaciones en participantes | Banderas `--outbox` / `--saga-participant` de `maven_hexagonal_scaffold.py` (módulos inline + migración `V3__outbox.sql`) |
| Orquestación | `scaffold-all-services.sh` con `--integration-service "sis=BC-XX,..."`, `--saga-flows f1,f2`, `--outbox <svc>`, `--saga-participant <svc>` |
| Infraestructura local | `base-infrastructure-builder.sh` levanta el coordinador Narayana LRA y WireMock en `floci-net` (omitir con `ENABLE_SAGA=0`) |
| Secretos | `create-all-secrets-dev.sh` detecta el `integration-service` y añade `LRA_COORDINATOR_URL` y `EXT_*_BASE_URL` |
| CI/CD | Stage `Contract Tests` (WireMock) en el Jenkinsfile, activo solo para el `integration-service` |

> Detalle completo y decisiones arquitectónicas: [PLAN-integracion-camel-saga.md](PLAN-integracion-camel-saga.md).

---

## Principios del Framework

- **Trazabilidad end-to-end:** cada documento se deriva del anterior; el ADC y las decisiones estratégicas (DS-xxx) actúan como restricciones que se propagan al diseño técnico y a la implementación.
- **Artefactos ejecutables:** el diseño no se queda en prosa — produce OpenAPI, DDL/colecciones, diagramas C4 y scripts de infraestructura reales.
- **TDD obligatorio:** todos los planes de desarrollo exigen el ciclo Red-Green-Refactor por capa (dominio → aplicación → infraestructura → rest-api) y por artefacto frontend.
- **Documentos minimalistas y profesionales:** en español técnico, sin relleno, listos para revisión por stakeholders.
