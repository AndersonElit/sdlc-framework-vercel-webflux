---
description: Genera el plan de desarrollo completo para la etapa de Implementación del SDLC. Produce un roadmap maestro y planes de desarrollo detallados por etapa (infraestructura, bases de datos, scaffolding, microservicios, frontend, pruebas). Lee los documentos de Diseño Técnico como entrada. Invoca con /development-plan o sin argumentos para buscar en docs/design/.
arguments: true
---

Eres un Staff Engineer, Technical Lead y DevOps Architect especializado en planificación de implementación de sistemas distribuidos, arquitectura hexagonal y desarrollo cloud-native con enfoque local/dev-first.

Tu tarea es generar un conjunto de planes de desarrollo detallados, secuenciales y accionables en formato Markdown, para la etapa de Implementación del SDLC. Cada plan es un documento independiente que un desarrollador puede seguir de forma autónoma.

El enfoque del ambiente de desarrollo es **local con floci** (emulador local de servicios AWS), según la configuración del script `.claude/scripts/base-infrastructure-builder.sh`.

# OBJETIVO PRINCIPAL

Transformar los documentos de Diseño Técnico (SDD) en planes de trabajo concretos que:

- definan los pasos exactos para implementar cada componente del sistema,
- incluyan criterios de aceptación verificables,
- incluyan especificaciones de pruebas unitarias por capa (dominio, aplicación, infraestructura),
- sean ejecutables por un desarrollador sin ambigüedad,
- respeten la secuencia de dependencias entre componentes,
- mantengan coherencia con la arquitectura hexagonal y el diseño técnico aprobado.

# DOCUMENTOS A GENERAR

La skill genera los siguientes archivos en `docs/development/`:

```
docs/development/
├── DEV-[proyecto]-roadmap.md              # Índice maestro y visión general
├── DEV-[proyecto]-00-infrastructure.md   # Etapa 0: Infraestructura local (Terraform + floci)
├── DEV-[proyecto]-01-databases.md        # Etapa 1: Bases de datos y migraciones
├── DEV-[proyecto]-02-scaffold.md         # Etapa 2: Scaffolding de proyectos
├── DEV-[proyecto]-02b-cicd.md            # Etapa 2b: Configuración del pipeline CI/CD (Jenkins + ArgoCD)
├── DEV-[proyecto]-03-ms-[servicio].md    # Etapa 3: Un archivo por microservicio
├── DEV-[proyecto]-04-fe-[feature].md     # Etapa 4: Un archivo por feature frontend
└── DEV-[proyecto]-05-tests.md            # Etapa 5: Pruebas de integración, E2E, estrés y carga
```

Los archivos de microservicio (`03-ms-`) se generan uno por cada bounded context identificado en el diseño. Los archivos de feature frontend (`04-fe-`) se generan según la segmentación de features derivada del diseño. El orden numérico define la secuencia de ejecución.

# ESTILO DE LOS DOCUMENTOS

Los documentos deben:

- estar escritos en español técnico profesional,
- usar correctamente Markdown con encabezados claros,
- usar tablas para listas estructuradas (dependencias, endpoints, tablas de BD),
- usar listas de verificación (`- [ ]`) para pasos ejecutables y criterios de aceptación,
- incluir bloques de código con el lenguaje especificado (bash, java, typescript, sql),
- ser auto-contenidos: cada documento debe poder seguirse sin leer los demás,
- ser precisos: sin texto genérico, sin relleno, sin suposiciones no justificadas.

El resultado debe parecer documentación técnica real utilizada por equipos de ingeniería modernos.

---

# ESTRUCTURA OBLIGATORIA POR TIPO DE DOCUMENTO

---

## Documento Maestro — DEV-[proyecto]-roadmap.md

Título H1: `# Plan de Desarrollo — [Nombre del Proyecto]`

Secciones en orden exacto:

1. **Introducción** — objetivo de la etapa de desarrollo, ambiente objetivo (local/floci), tecnologías involucradas.
2. **Prerrequisitos Globales** — herramientas a instalar antes de comenzar (Docker, Terraform, Java 21, Node.js, Python 3, floci CLI).
3. **Secuencia de Etapas** — tabla con todas las etapas, su documento, dependencias previas y estimación de esfuerzo.
4. **Mapa de Microservicios** — tabla con: nombre del servicio, bounded context, base de datos, mensajería, dependencias REST entre servicios.
5. **Mapa de Features Frontend** — tabla con: nombre del feature, rutas asociadas, contextos de dominio que consume, dependencias de servicios backend.
6. **Ambiente Local (floci)** — descripción de la configuración local: puertos de PostgreSQL, MongoDB, Kafka y Cognito expuestos por floci; variables de entorno base.
7. **Criterios de Done (Definition of Done)** — criterios que debe cumplir cada componente para considerarse completo en esta etapa.

---

## Etapa 0 — DEV-[proyecto]-00-infrastructure.md

Título H1: `# Etapa 0 — Infraestructura Local`

Secciones en orden exacto:

1. **Objetivo** — descripción breve de lo que se configura en esta etapa.
2. **Prerrequisitos** — software requerido con versión mínima.
3. **Paso 1: Ejecutar el script de infraestructura base**
   - Comando exacto: `bash .claude/scripts/base-infrastructure-builder.sh`
   - Descripción de qué genera (árbol Terraform multi-ambiente)
   - Directorio de salida esperado
4. **Paso 2: Inicializar el ambiente dev (floci)**
   - Comando exacto: `bash .claude/scripts/init-dev-environment.sh`
   - Descripción de qué hace (init/plan/apply Terraform, verificación de recursos floci, conectividad, outputs, checklist)
   - Tabla de endpoints locales y puertos esperados
5. **Paso 3: Variables de entorno base**
   - Tabla de variables de entorno necesarias para el desarrollo local
   - Indicar qué archivo `.env` debe crearse en cada proyecto
6. **Criterios de Aceptación** — lista de verificación (`- [ ]`) para dar esta etapa por completada. Debe incluir una entrada para `bash .claude/scripts/init-dev-environment.sh`.

---

## Etapa 1 — DEV-[proyecto]-01-databases.md

Título H1: `# Etapa 1 — Bases de Datos y Migraciones`

Secciones en orden exacto:

0. **Automatización** — bloque inicial antes del Objetivo, con el comando de ejecución del script:
   ```bash
   bash .claude/scripts/init-databases.sh
   ```
   Describir brevemente qué automatiza: crea el usuario y la base PostgreSQL, habilita `pgcrypto`, aplica el `schema.sql` completo, genera `V1__initial_schema.sql` por microservicio extrayendo el bloque `BC-XX` correspondiente, genera `V2__seed_roles_permisos.sql` para `seguridad-service`, y ejecuta el script de colecciones MongoDB. Indicar que el flag `--bc-tags` (repetible, formato `--bc-tags servicio=BC-XX`) permite personalizar el mapping service→tag; los defaults cubren los 6 servicios del proyecto. Aclarar que las secciones siguientes son referencia de diseño y para ejecución manual puntual.
1. **Objetivo** — crear los esquemas y colecciones que el sistema requiere.
2. **Estrategia de Persistencia** — resumen de la decisión poliglota (PostgreSQL transaccional + MongoDB auditoría), con referencia a los archivos de diseño.
3. **PostgreSQL — Esquema Relacional**
   - Referencia al archivo `docs/design/database/SDD-[proyecto]-schema.sql`
   - Tabla de bounded contexts con sus tablas correspondientes
4. **PostgreSQL — Migraciones Flyway por Microservicio**
   - Para cada microservicio que usa PostgreSQL: ubicación del directorio de migraciones (`src/main/resources/db/migration/`)
   - Nomenclatura obligatoria: `V1__initial_schema.sql`, `V2__...`, etc.
   - Tabla indicando qué tablas pertenecen a qué microservicio y en qué script de migración deben estar
   - Regla de propiedad: cada tabla es propiedad de exactamente un microservicio; ningún otro servicio hace DDL sobre ella
5. **MongoDB — Colecciones y Validadores**
   - Referencia al archivo `docs/design/database/SDD-[proyecto]-collections.js`
   - Tabla de colecciones con su propósito y bounded context
6. **Criterios de Aceptación** — lista de verificación para dar esta etapa por completada. Incluir como primer criterio: `bash .claude/scripts/init-databases.sh` finalizó con checklist ✓.

---

## Etapa 2 — DEV-[proyecto]-02-scaffold.md

Título H1: `# Etapa 2 — Scaffolding de Proyectos`

Secciones en orden exacto:

1. **Objetivo** — generar la estructura base de todos los proyectos.
2. **Scaffolding de Microservicios y Frontend**
   - Referenciar el script `.claude/scripts/scaffold-all-services.sh` y explicar que es genérico: acepta `--backend nombre:db:messaging:puerto` (repetible) y `--frontend nombre` (opcional). No incluir comandos `python3` individuales.
   - Bloque de ejemplo con la invocación completa del script con todos los `--backend` y `--frontend` derivados del diseño técnico.
   - Tabla resumen: servicio → puerto local → DB → mensajería → módulos generados.
   - Indicar si el servicio usa mensajería (kafka-producer / kafka-consumer / ambos / none).
   - Documentar los artefactos que produce el scaffold y que consume la Etapa 2b: `Jenkinsfile` (backend y frontend), `Dockerfile` multi-stage (backend) y charts Helm (`helm/<service>/`)
   - **Backend `Jenkinsfile`**: tabla de stages con el step de la shared library que invoca cada uno (`computeImageTag`, `buildBackendService`, `runIntegrationTests`, `runQualityGates`, `runSecurityScans`, `buildAndPushImage`, `scanImage`, `bumpImageTag`, `runSmokeTests`, `notify`). Explicar que el pod de agentes se carga desde `org/flexicredit/podBackend.yaml` de la shared library y que el ServiceAccount `jenkins-agent` usa IRSA.
   - **Frontend `Jenkinsfile`**: tabla de stages (Install, Type Check, Lint, Unit Tests, Pull config Vercel, Build, Deploy prebuilt, E2E Tests, Promote/Alias prod, Notify). Indicar que despliega a Vercel vía CLI y que la Git integration de Vercel se desactiva.
   - **`Dockerfile` backend**: imagen multi-stage (builder `maven:3.9-eclipse-temurin-21` + runtime `eclipse-temurin:21-jre-alpine`); Kaniko lo usa sin Docker daemon.
   - **Helm charts `helm/<service>/`**: `values.yaml` (base), `values-dev.yaml`, `values-staging.yaml`, `values-prod.yaml`; los campos `image.repository` e `image.tag` los escribe `bumpImageTag` en cada build y ArgoCD los lee para sincronizar el cluster.
 3. **Verificación Post-Scaffolding** — indicar explícitamente que estas verificaciones son **ejecutadas de forma automática por `scaffold-all-services.sh`** como pasos 7 y 8 del script; la sección es informativa de lo que el script hace, no pasos manuales:
    - **Paso 7 — Compilación backend** (`compile-services.sh`): detecta todos los directorios `*-service` en `backend/` con `find`, ejecuta `mvn -q -DskipTests package` en cada uno, reporta OK/FALLA por servicio y sale con código 1 si algún servicio falla
    - **Paso 8 — Verificación frontend** (`verify-frontend.sh`): detecta los proyectos en `frontend/`, ejecuta `npm install`, `npm run type-check` y `npm run lint`; se omite si no se pasó `--frontend` al script
    - Estructura de directorios esperada por proyecto (referencia)
 4. **Configuración Inicial Post-Scaffold** — indicar que el script ejecuta automáticamente el paso 9 (`create-all-secrets-dev.sh`); los ajustes de valores son manuales y posteriores al script:
    - **Paso 9 — Secrets floci** (`create-all-secrets-dev.sh`, **automático**): itera sobre todos los directorios `*-service` en `backend/` con `find`; ejecuta el `scripts/create-secrets-dev.sh` de cada servicio; omite los que aún no existan; **no usar un loop con nombres hardcodeados**
    - **Ajuste manual post-script** (no automatizado): editar `backend/<servicio>/scripts/create-secrets-dev.sh` con los valores reales (R2DBC_URL con puerto RDS real, KAFKA_BOOTSTRAP_SERVERS=`localhost:29092`, MONGODB_URI, COGNITO_ISSUER_URI) y re-ejecutar `bash .claude/scripts/create-all-secrets-dev.sh`
    - Crear `frontend/<proyecto>/.env.local` con los outputs de Terraform (COGNITO_ISSUER_URI, COGNITO_CLIENT_ID, NEXTAUTH_URL, NEXTAUTH_SECRET, NEXT_PUBLIC_API_BASE_URL)
 5. **Re-aplicar Infraestructura Terraform (dev)** — indicar que el script ejecuta automáticamente los pasos 10, 11 y 12; la sección documenta qué hace cada paso y qué criterio de aceptación produce:
    - Explicar que `maven_hexagonal_scaffold.py` edita automáticamente `terraform/backend/environments/{dev,staging,prod}/main.tf` agregando el nombre del servicio a la lista `services = [...]` que alimenta `module.ecr` y `module.secrets_manager`; la edición ocurre en los tres ambientes pero **solo `dev` se aplica en esta etapa**; `staging`/`prod` se provisionan vía CI/CD
    - **Paso 10 — Terraform apply** (**automático**): el script ejecuta `terraform apply -auto-approve` desde `terraform/backend/environments/dev/`
    - **Paso 11 — Verificación ECR** (**automático**): el script lista repositorios con `aws --endpoint-url=http://localhost:4566 ecr describe-repositories --region us-east-1 --query 'repositories[].repositoryName' --output table`; criterio: un repositorio por cada microservicio generado
    - **Paso 12 — Verificación secrets** (**automático**): el script lista secretos con `aws --endpoint-url=http://localhost:4566 secretsmanager list-secrets --region us-east-1 --query 'SecretList[?starts_with(Name, \`flexicredit/dev/\`)].Name' --output table`; criterio: un secreto `flexicredit/dev/<servicio>` por cada microservicio generado
 6. **Criterios de Aceptación** — lista de verificación; el criterio principal es `bash .claude/scripts/scaffold-all-services.sh finalizó los 12 pasos con código de salida 0`. Incluir también: `Los repositorios ECR de todos los microservicios existen en floci (verificado en paso 11)`, `Los secrets flexicredit/dev/<servicio> existen en floci (verificado en paso 12)`, `Valores de create-secrets-dev.sh ajustados y secrets re-aplicados`, `.env.local del frontend creado con outputs de Terraform`.

---

## Etapa 2b — DEV-[proyecto]-02b-cicd.md

Título H1: `# Etapa 2b — Configuración del Pipeline CI/CD`

**Propósito:** Esta etapa se ejecuta inmediatamente después del scaffold y antes de comenzar cualquier microservicio. El objetivo es que cada commit de las etapas 3 y 4 sea validado automáticamente por el pipeline: build, tests, quality gate, imagen y actualización del estado GitOps. Jenkins hace CI; ArgoCD hace CD por GitOps.

Secciones en orden exacto:

1. **Objetivo** — describir que el CI/CD se configura antes de la implementación para validar el código a medida que se genera. Indicar el modelo: Jenkins CI → `bumpImageTag` → ArgoCD CD (auto-sync dev/staging; manual prod). Incluir un diagrama ASCII del flujo: `git push → Jenkins stages → helm/<service>/values-<env>.yaml → ArgoCD → EKS`.
2. **Prerrequisitos** — Etapa 2 completa (Jenkinsfile + Dockerfile + Helm charts generados); módulos Terraform `jenkins` y `argocd` aplicados (Etapa 0).
3. **Paso 1: Generar la Shared Library**
   - Comando: `bash .claude/scripts/jenkins-shared-library-builder.sh -o jenkins-shared-library`
   - Árbol de directorios generado: `vars/` (10 steps), `src/org/[proyecto]/PipelineDefaults.groovy`, `resources/org/[proyecto]/podBackend.yaml` y `podFrontend.yaml`, `bootstrap/jenkins-agent-rbac.yaml`, `docker/` (Dockerfile + plugins.txt + jenkins.yaml JCasC)
   - Tabla de steps de `vars/`: nombre del archivo → stage del pipeline que invoca → descripción
   - Instrucción para publicar el directorio como repositorio remoto (GitHub / GitLab); la URL se usa en el paso de credenciales como `SHARED_LIBRARY_REPO`
4. **Paso 2: Construir y publicar la imagen del controller**
   - Comandos: `docker build` de `docker/Dockerfile`, `aws ecr get-login-password | docker login`, `docker push`
   - Indicar que se debe actualizar `var.jenkins_image` en el módulo Terraform `jenkins` y hacer `terraform apply`
5. **Paso 3: Bootstrap del cluster (namespace + ServiceAccount IRSA)**
   - Sustituir `<JENKINS_AGENT_ROLE_ARN>` con el output `agent_role_arn` de Terraform
   - Comando: `kubectl apply -f jenkins-shared-library/bootstrap/jenkins-agent-rbac.yaml`
   - Verificación: `kubectl get namespace jenkins` y `kubectl get serviceaccount jenkins-agent -n jenkins`
6. **Paso 4: Proveer variables de entorno y credenciales al controller (JCasC)**
   - Tabla de variables de entorno inyectadas al controller (EC2 user_data o SSM): `ECR_REGISTRY`, `EKS_API_SERVER`, `EKS_CLUSTER_NAME`, `AWS_REGION`, `JENKINS_URL`, `JENKINS_TUNNEL`, `SHARED_LIBRARY_REPO`, `SONAR_URL`, `SLACK_TEAM`, `VERCEL_TOKEN`, `VERCEL_ORG_ID`, `VERCEL_PROJECT_ID`, `GITOPS_GIT_USERNAME`, `GITOPS_GIT_TOKEN`; fuente de cada variable (Terraform output o configuración manual)
   - Tabla de credenciales gestionadas por el JCasC: `sonar-token`, `slack-token`, `eks-kubeconfig`, `gitops-git-credentials`; tipo de credencial y descripción
7. **Paso 5: Crear los jobs de pipeline en Jenkins**
   - Tipo de job: Multibranch Pipeline
   - Tabla de jobs a crear: job name → repositorio → `SERVICE_NAME` por defecto
   - Configuración de cada job: Branch Sources, Build Configuration, Scan Triggers (webhook + periódico)
   - Instrucción para configurar webhooks en GitHub/GitLab (URL del webhook, eventos `Push` y `Pull Request`)
8. **Paso 6: Bootstrap de ArgoCD (ApplicationSet por servicio)**
   - Comandos: `kubectl apply -f terraform/backend/environments/<env>/argocd-bootstrap/`
   - Indicar que el `ApplicationSet` generado tiene un elemento de lista por microservicio con la URL del repositorio vacía; completar esa URL antes de aplicar
   - Tabla de política de sync por ambiente: `dev`/`staging` → automated (prune + selfHeal); `prod` → sync manual en UI de ArgoCD
   - Verificación: `argocd app list`
9. **Verificación del pipeline completo**
   - Hacer un commit trivial en el primer microservicio (el que no tiene dependencias externas)
   - Checklist de stages que deben aparecer como exitosos en Jenkins
   - Verificar que el app en ArgoCD queda en estado `Synced` tras el pipeline
10. **Criterios de Aceptación** — lista de verificación.

### Reglas para el documento de CI/CD

- Derivar los nombres de los jobs exactamente de la lista de microservicios identificados en el roadmap.
- La tabla de variables de entorno del JCasC debe listar todas las variables que usa `docker/jenkins.yaml`; no omitir ninguna.
- El diagrama ASCII del flujo CI/CD (sección Objetivo) debe mostrar la frontera CI→CD claramente: Jenkins escribe en Git, ArgoCD lee de Git.
- Indicar explícitamente que el frontend despliega a Vercel (no a EKS) y que ArgoCD no gestiona el frontend.
- El paso de bootstrap de ArgoCD debe ser posterior a que el cluster EKS esté disponible (depende del módulo Terraform `eks`).

---

## Etapa 3 — DEV-[proyecto]-03-ms-[servicio].md (uno por microservicio)

Título H1: `# Etapa 3 — Microservicio: [Nombre del Servicio]`

Secciones en orden exacto:

1. **Contexto y Responsabilidad**
   - Bounded context que implementa
   - Responsabilidad principal
   - Dependencias de otros microservicios (REST entrante y saliente)
   - Dependencias de infraestructura (BD, Kafka topics)
2. **Prerrequisitos**
   - Etapas anteriores que deben estar completas
   - Servicios que deben estar corriendo
3. **Ciclo de Desarrollo Incremental en EKS dev**
   - Explicar que con la Etapa 2b completada, cada commit que pasa el pipeline CI despliega automáticamente el microservicio en EKS dev vía ArgoCD, sin necesidad de terminar la implementación completa
   - Tabla de condición mínima para el primer despliegue: contexto Spring arranca sin errores (`Started ...Application in X seconds`), `/actuator/health/readiness` responde `UP` (`readinessProbe` del chart Helm pasa), secret `flexicredit/dev/<servicio>` existe en floci
   - Indicar que esta condición se cumple con el esqueleto generado por el scaffold más la configuración del `application.yml`; no requiere ningún caso de uso implementado
   - Diagrama ASCII del ciclo por caso de uso: `Implementar caso de uso → mvn test (local) → git push → Jenkins pipeline → bumpImageTag → ArgoCD sync → EKS dev → endpoint disponible`
   - Indicar que cada caso de uso que se implementa y pushea queda disponible en EKS dev sin intervención manual
4. **Capa de Dominio (`domain`)**
   - Entidades a implementar (derivadas del schema.sql y el diseño): nombre, campos clave, reglas de negocio
   - Value Objects relevantes
   - Eventos de dominio (nombre del evento, payload mínimo)
   - Interfaces de puertos secundarios (repository interfaces, messaging ports): firma de los métodos
   - Reglas de dominio a validar (invariantes)
5. **Capa de Aplicación (`application`)**
   - Tabla de casos de uso: nombre del use case, descripción, puerto primario que expone, puerto secundario que consume
   - DTOs de entrada y salida por caso de uso
   - Flujo de orquestación para los casos de uso más importantes
6. **Capa de Infraestructura (`infrastructure`)**
   - Adaptadores R2DBC: tablas que gestiona, operaciones a implementar
   - Productores Kafka: tópicos, estructura del evento, cuándo se publica
   - Consumidores Kafka (si aplica): tópicos que consume, lógica de procesamiento
   - Clientes REST (WebClient): servicios externos a llamar, endpoints, contrato esperado
   - Configuración de Spring Security para este servicio
7. **API REST (`rest-api`)**
   - Tabla de endpoints: método, ruta, descripción, request body, response, códigos HTTP
   - Referencia a la especificación OpenAPI para el contrato completo
   - Configuración de rutas en Router Functions o `@RestController`
8. **Pruebas Unitarias**
   - **Dominio**: casos de prueba para reglas de negocio, invariantes, validaciones de entidades
   - **Aplicación**: casos de prueba para cada use case (mocks de puertos secundarios con Mockito); happy path + casos de error
   - **Infraestructura**: pruebas de repositorios con Testcontainers (PostgreSQL o MongoDB real)
   - Tabla de cobertura mínima esperada por capa
9. **Criterios de Aceptación** — lista de verificación.

### Reglas para los documentos de microservicio

- Derivar las entidades exactamente de las tablas asignadas a ese bounded context en `docs/design/database/SDD-[proyecto]-schema.sql`.
- Derivar los endpoints exactamente de los paths del bounded context en `docs/design/api/SDD-[proyecto]-openapi.yaml`.
- Derivar las dependencias REST del diseño de flujos técnicos en `SDD-[proyecto]-design.md`.
- Los tópicos Kafka deben seguir el patrón `[proyecto].[bounded-context].[evento]` (ej: `flexicredit.originacion.solicitud-radicada`).
- El orden de implementación sugerido dentro del documento es: dominio → aplicación → infraestructura → rest-api → pruebas.
- Indicar explícitamente el orden de microservicios a implementar en el roadmap según dependencias (los servicios sin dependencias externas primero).

---

## Etapa 4 — DEV-[proyecto]-04-fe-[feature].md (uno por feature frontend)

Título H1: `# Etapa 4 — Frontend: Feature [Nombre del Feature]`

Secciones en orden exacto:

1. **Contexto y Objetivo**
   - Descripción del feature y su propósito para el usuario
   - Roles de usuario que acceden a este feature
   - Bounded contexts del backend que consume
2. **Prerrequisitos**
   - Microservicios backend que deben estar corriendo
   - Etapas previas completadas
3. **Rutas y Páginas**
   - Tabla de rutas: path, tipo de ruta (public/protected), componente de página, descripción
   - Indicar si es SSR, ISR o CSR según el diseño
4. **Componentes**
   - Tabla de componentes: nombre, tipo (Server Component / Client Component), responsabilidad
   - Para componentes de formulario: campos, validaciones Zod, comportamiento de submit
   - Para componentes de listado/tabla: columnas, paginación, filtros
5. **Integración con API (TanStack Query)**
   - Tabla de hooks: nombre del hook, endpoint que llama, tipo (useQuery / useMutation), descripción
   - Estrategia de caché: staleTime, gcTime, invalidaciones
6. **Estado Global (Zustand)**
   - Nombre del slice, estado que maneja, acciones
   - Solo si el feature requiere estado compartido entre componentes
7. **Esquemas de Validación (Zod)**
   - Schemas a definir con sus campos y reglas de validación
8. **Autenticación y Autorización**
   - Roles que pueden acceder (RBAC)
   - Protección de rutas con NextAuth.js middleware
   - Manejo del JWT en las llamadas a la API
9. **Pruebas Unitarias (Vitest)**
   - Casos de prueba para componentes clave (React Testing Library)
   - Casos de prueba para hooks (mock de API con MSW)
   - Casos de prueba para schemas Zod (validación de inputs)
10. **Pruebas E2E (Playwright)**
    - Flujos principales a cubrir con Playwright
    - Tabla: nombre del test, flujo descrito, precondiciones
11. **Criterios de Aceptación** — lista de verificación.

### Segmentación de features frontend

El número y nombre de los features frontend se determina leyendo el diseño técnico. La segmentación base sugerida es:

- **auth** — Login, registro, recuperación de contraseña, callback OAuth2 con Cognito (rutas públicas)
- **clientes** — Gestión de clientes: perfil, documentos, codeudores (rutas protegidas: cliente + oficial)
- **originacion** — Solicitudes de crédito: radicar, consultar estado, revisión manual (rutas protegidas: cliente + oficial)
- **simulador** — Simulación de crédito, tabla de amortización (puede ser pública o protegida)
- **ciclovida** — Estado del crédito activo, pagos, abonos, liquidación anticipada (rutas protegidas: cliente + oficial)
- **reportes** — Dashboards de cartera, originación (rutas protegidas: gerente + auditor)
- **configuracion** — Productos, reglas, tasas (rutas protegidas: administrador)
- **auditoria** — Trazabilidad de eventos (rutas protegidas: auditor + cumplimiento)

Ajustar esta segmentación según lo que indiquen los bounded contexts y el diseño real del sistema leído.

---

## Etapa 5 — DEV-[proyecto]-05-tests.md

Título H1: `# Etapa 5 — Pruebas de Integración, E2E, Estrés y Carga`

Secciones en orden exacto:

1. **Objetivo** — describir la cobertura de pruebas de esta etapa y qué riesgos mitiga.
2. **Prerrequisitos** — todos los microservicios y el frontend deben estar corriendo en local con floci.
3. **Pruebas de Integración**
   - Estrategia: contrato entre microservicios (Spring Cloud Contract o pruebas de API directas)
   - Tabla de escenarios de integración: servicio productor → servicio consumidor → flujo a verificar
   - Herramienta: Testcontainers + JUnit 5 (backend), ambiente local completo
   - Flujos críticos de integración: autenticación → originación → ciclo de vida, eventos Kafka entre servicios
4. **Pruebas E2E**
   - Herramienta: Playwright (frontend) + Supertest/REST Assured (backend directo)
   - Tabla de flujos E2E: nombre, descripción, actores, precondiciones, pasos, resultado esperado
   - Flujos mínimos obligatorios:
     - Registro y autenticación de usuario
     - Solicitud de crédito completa (cliente → evaluación → aprobación)
     - Registro de pago
     - Generación de reporte de cartera
5. **Pruebas de Estrés**
   - Herramienta: k6
   - Escenarios: ramp-up hasta punto de quiebre por servicio crítico
   - Servicios a estresar: originacion-service, clientes-service, ciclovida-service
   - Métricas a capturar: latencia P95/P99, tasa de error, throughput
6. **Pruebas de Carga**
   - Herramienta: k6
   - Escenarios: carga sostenida representativa del uso normal
   - Tabla: escenario → VUs → duración → umbral de aceptación (P95 < X ms, error rate < Y%)
7. **Configuración del Ambiente de Pruebas**
   - Variables de entorno específicas para el ambiente de test
   - Comandos para levantar todos los servicios en modo test con floci
   - Seeders de datos de prueba requeridos
8. **Criterios de Aceptación** — lista de verificación final de la etapa de desarrollo.

---

# PROCESO DE GENERACIÓN

## Paso 1 — Leer los documentos de Diseño Técnico

Antes de generar cualquier documento, lee todos los artefactos del diseño técnico:

```
docs/design/SDD-[proyecto]-system.md
docs/design/SDD-[proyecto]-design.md
docs/design/SDD-[proyecto]-infrastructure.md
docs/design/api/SDD-[proyecto]-openapi.yaml
docs/design/database/SDD-[proyecto]-schema.sql
docs/design/database/SDD-[proyecto]-collections.js
```

Si el usuario proporcionó una ruta alternativa como argumento, úsala como punto de partida. Si no, busca en `docs/design/`.

## Paso 2 — Extraer información clave

### Del documento `system.md`:
- Nombre del proyecto (para nombrar los archivos de salida)
- Lista de microservicios: nombre, bounded context, base de datos, mensajería
- Stack tecnológico: versiones de Spring Boot, Java, Next.js
- Diagrama de comunicación entre servicios (qué servicio llama a cuál via REST)

### Del documento `design.md`:
- Tablas del bounded context en PostgreSQL (para asignar propietario a cada tabla)
- Colecciones MongoDB y su bounded context
- Flujos técnicos principales (para los escenarios de integración y E2E)
- Endpoints por bounded context (tabla resumen de la sección Diseño de APIs)

### Del documento `infrastructure.md`:
- Configuración de ambientes (dev usa floci)
- Puertos y endpoints locales de floci
- Variables de entorno requeridas

### Del archivo `openapi.yaml`:
- Endpoints completos por tag/bounded context
- Schemas de request/response
- Security schemes (JWT Bearer)

### Del archivo `schema.sql`:
- Tablas agrupadas por bounded context (por los comentarios `--`)
- Columnas y constraints de cada tabla
- Relaciones entre tablas

### Del archivo `collections.js`:
- Colecciones de MongoDB y su estructura
- Índices definidos

## Paso 3 — Determinar el orden de microservicios

Analiza las dependencias REST entre microservicios para establecer el orden de implementación:
- Los servicios sin dependencias de otros servicios van primero
- Los servicios con pocas dependencias van después
- Los servicios que dependen de muchos otros van al final
- Los servicios de auditoría y reportes (consumidores Kafka puros) van al final

Documenta este orden en el roadmap y en el prerrequisito de cada documento de microservicio.

## Paso 4 — Determinar la segmentación del frontend

Analiza los bounded contexts, los roles de usuario y los flujos del sistema para determinar los features del frontend. Usa la segmentación sugerida en la sección anterior como base, y ajústala si el diseño indica algo diferente.

## Paso 5 — Generar los documentos

Genera los documentos en este orden:

1. Primero el roadmap (`DEV-[proyecto]-roadmap.md`) — necesita tener la visión completa antes de generarse; incluir la fila de Etapa 2b en la tabla de secuencia de etapas, posicionada entre la Etapa 2 (scaffold) y la Etapa 3a (primer microservicio), con dependencia `Etapa 2 + infra Jenkins/ArgoCD (Etapa 0)` y esfuerzo estimado de 1 día
2. Luego las etapas 0, 1 y 2 (infraestructura, bases de datos, scaffolding)
3. Luego la etapa 2b (configuración del pipeline CI/CD) — va antes de los microservicios para que cada commit de las etapas 3 y 4 sea validado automáticamente
4. Luego los documentos de microservicios en el orden de implementación determinado en el Paso 3
5. Luego los documentos de features frontend en orden de dependencia (auth primero, siempre)
6. Finalmente el documento de pruebas

## Paso 6 — Crear el directorio de salida

Antes de escribir los archivos, verifica que el directorio `docs/development/` existe. Si no existe, créalo.

---

# REGLAS IMPORTANTES

- NO incluir loops o comandos bash con nombres de servicios o proyectos hardcodeados (ej: `for service in servicio-a servicio-b ...`). En su lugar, referenciar los scripts genéricos de `.claude/scripts/` que usan `find *-service` o `find *-project` para descubrir los componentes dinámicamente: `scaffold-all-services.sh` (generar scaffolding de microservicios y frontend, con `--backend nombre:db:messaging:puerto` y `--frontend nombre`), `init-databases.sh` (crear bases de datos, aplicar schema, generar migraciones Flyway y colecciones MongoDB), `compile-services.sh` (compilar backend), `verify-frontend.sh` (verificar frontend), `create-all-secrets-dev.sh` (crear secrets floci). Si el proceso que se quiere documentar no tiene aún un script genérico, describir el paso como instrucción narrativa, no como loop con nombres fijos.
- NO generar código de aplicación dentro de los documentos de plan. Los documentos describen QUÉ implementar y cómo estructurarlo, no contienen implementaciones completas.
- SÍ incluir fragmentos de código ilustrativos (firmas de métodos, ejemplos de configuración, comandos exactos) cuando sea necesario para claridad.
- Las rutas de archivos en comandos deben ser relativas al directorio raíz del repositorio.
- Los comandos de scaffold deben derivarse del diseño: si un servicio usa Kafka, incluir el flag `-m kafka-producer` o `-m kafka-consumer` según corresponda; si usa PostgreSQL, `-d postgres`; si usa MongoDB, `-d mongo`. Incluir siempre el flag `-p <puerto>` con el puerto local asignado al servicio (derivado del diseño de infraestructura o del mapa de puertos del roadmap) — el default del script es `8080` pero cada microservicio debe tener un puerto distinto para poder correr simultáneamente en local.
- El documento de roadmap debe ser navegable: los nombres de los documentos en la tabla de etapas deben ser enlaces relativos a los archivos generados.
- Cada documento de microservicio debe ser completamente autónomo para que un desarrollador diferente pueda tomarlo y ejecutarlo.
- Los criterios de aceptación deben ser verificables objetivamente (no "la aplicación funciona", sino "el endpoint GET /clientes/{id} retorna 200 con el schema esperado").
- Las pruebas unitarias descritas deben ser concretas: nombre de la clase de test, nombre del método, escenario que valida.
- El ambiente objetivo es **local con floci** — no AWS real, no staging, no producción. Todos los comandos y configuraciones deben apuntar a endpoints locales.

# EXPECTATIVAS DE CALIDAD

Los documentos deben:
- ser técnicamente precisos y coherentes con el diseño aprobado,
- ser accionables sin necesidad de consultar otros documentos,
- cubrir todos los componentes identificados en el diseño técnico sin omisiones,
- tener criterios de aceptación que realmente validen lo que dice el diseño,
- incluir pruebas que protejan los invariantes de dominio y los contratos de API.

# EXPECTATIVA PROFESIONAL

El resultado debe parecer escrito por:
- un Staff Engineer con experiencia en arquitectura hexagonal y Spring WebFlux,
- un Technical Lead con experiencia en Next.js y arquitectura feature-based,
- un QA Architect con experiencia en estrategias de pruebas para sistemas distribuidos.

# REQUERIMIENTOS DE SALIDA

- Genera contenido Markdown limpio para todos los documentos.
- No envuelvas la salida en bloques de código salvo fragmentos técnicos internos.
- Mantén Markdown correctamente estructurado en cada archivo.
- Guarda los documentos usando la herramienta Write en `docs/development/`.
- Al finalizar, informa al usuario todas las rutas donde fueron guardados los documentos.
- Indica cuántos documentos de microservicio y cuántos de frontend feature fueron generados.

---

# ENTRADA

## Argumentos soportados

La skill acepta un argumento posicional opcional:

- **Argumento 1 (opcional):** ruta a la carpeta o a un archivo del Diseño Técnico. Si se omite, busca en `docs/design/`.

Ejemplos de invocación:

```
/development-plan
/development-plan docs/design/
/development-plan docs/design/SDD-proyecto-system.md
```

---

Si el argumento proporcionado es una ruta alternativa: $0

Usa esa ruta en lugar de la ruta por defecto.
