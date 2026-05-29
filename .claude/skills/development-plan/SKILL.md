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
   - Comandos Terraform para el ambiente `dev`
   - Verificación de recursos floci levantados (PostgreSQL local, MongoDB local, Kafka local, Cognito local)
   - Tabla de endpoints locales y puertos esperados
5. **Paso 3: Verificar conectividad**
   - Checklist de verificación con comandos concretos (psql, mongosh, kafka-topics, etc.)
6. **Paso 4: Variables de entorno base**
   - Tabla de variables de entorno necesarias para el desarrollo local
   - Indicar qué archivo `.env` debe crearse en cada proyecto
7. **Criterios de Aceptación** — lista de verificación (`- [ ]`) para dar esta etapa por completada.

---

## Etapa 1 — DEV-[proyecto]-01-databases.md

Título H1: `# Etapa 1 — Bases de Datos y Migraciones`

Secciones en orden exacto:

1. **Objetivo** — crear los esquemas y colecciones que el sistema requiere.
2. **Estrategia de Persistencia** — resumen de la decisión poliglota (PostgreSQL transaccional + MongoDB auditoría), con referencia a los archivos de diseño.
3. **PostgreSQL — Esquema Relacional**
   - Referencia al archivo `docs/design/database/SDD-[proyecto]-schema.sql`
   - Tabla de bounded contexts con sus tablas correspondientes
   - Instrucciones para crear la base de datos local y ejecutar el schema
   - Comandos exactos (psql o docker exec)
4. **PostgreSQL — Migraciones Flyway por Microservicio**
   - Para cada microservicio que usa PostgreSQL: ubicación del directorio de migraciones (`src/main/resources/db/migration/`)
   - Nomenclatura obligatoria: `V1__initial_schema.sql`, `V2__...`, etc.
   - Tabla indicando qué tablas pertenecen a qué microservicio y en qué script de migración deben estar
   - Regla de propiedad: cada tabla es propiedad de exactamente un microservicio; ningún otro servicio hace DDL sobre ella
5. **MongoDB — Colecciones y Validadores**
   - Referencia al archivo `docs/design/database/SDD-[proyecto]-collections.js`
   - Instrucciones para ejecutar el script contra la instancia local de MongoDB
   - Tabla de colecciones con su propósito y bounded context
6. **Criterios de Aceptación** — lista de verificación para dar esta etapa por completada.

---

## Etapa 2 — DEV-[proyecto]-02-scaffold.md

Título H1: `# Etapa 2 — Scaffolding de Proyectos`

Secciones en orden exacto:

1. **Objetivo** — generar la estructura base de todos los proyectos.
2. **Directorio de trabajo** — indicar que los microservicios se crean en `backend/` y el frontend en `frontend/`; crear estos directorios antes de ejecutar los scripts.
3. **Scaffolding de Microservicios**
   - Para cada microservicio: comando exacto con flags `-n`, `-d`, `-m` derivados del diseño técnico
   - Tabla resumen: servicio → comando completo → módulos generados
   - Indicar si el servicio usa mensajería (kafka-producer / kafka-consumer / ambos / none)
4. **Scaffolding del Frontend**
   - Comando exacto para el proyecto Next.js
5. **Verificación Post-Scaffolding**
   - Checklist: compilar cada microservicio (`mvn compile`), verificar que el frontend levanta (`npm run dev`)
   - Estructura de directorios esperada por proyecto
6. **Configuración Inicial Post-Scaffold**
   - Pasos para aplicar el `.env` local a cada proyecto
   - Ajustes mínimos al `application.yml` de cada microservicio para apuntar a floci
7. **Criterios de Aceptación** — lista de verificación.

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
3. **Capa de Dominio (`domain`)**
   - Entidades a implementar (derivadas del schema.sql y el diseño): nombre, campos clave, reglas de negocio
   - Value Objects relevantes
   - Eventos de dominio (nombre del evento, payload mínimo)
   - Interfaces de puertos secundarios (repository interfaces, messaging ports): firma de los métodos
   - Reglas de dominio a validar (invariantes)
4. **Capa de Aplicación (`application`)**
   - Tabla de casos de uso: nombre del use case, descripción, puerto primario que expone, puerto secundario que consume
   - DTOs de entrada y salida por caso de uso
   - Flujo de orquestación para los casos de uso más importantes
5. **Capa de Infraestructura (`infrastructure`)**
   - Adaptadores R2DBC: tablas que gestiona, operaciones a implementar
   - Productores Kafka: tópicos, estructura del evento, cuándo se publica
   - Consumidores Kafka (si aplica): tópicos que consume, lógica de procesamiento
   - Clientes REST (WebClient): servicios externos a llamar, endpoints, contrato esperado
   - Configuración de Spring Security para este servicio
6. **API REST (`rest-api`)**
   - Tabla de endpoints: método, ruta, descripción, request body, response, códigos HTTP
   - Referencia a la especificación OpenAPI para el contrato completo
   - Configuración de rutas en Router Functions o `@RestController`
7. **Pruebas Unitarias**
   - **Dominio**: casos de prueba para reglas de negocio, invariantes, validaciones de entidades
   - **Aplicación**: casos de prueba para cada use case (mocks de puertos secundarios con Mockito); happy path + casos de error
   - **Infraestructura**: pruebas de repositorios con Testcontainers (PostgreSQL o MongoDB real)
   - Tabla de cobertura mínima esperada por capa
8. **Criterios de Aceptación** — lista de verificación.

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

1. Primero el roadmap (`DEV-[proyecto]-roadmap.md`) — necesita tener la visión completa antes de generarse
2. Luego las etapas 0, 1 y 2 (infraestructura, bases de datos, scaffolding)
3. Luego los documentos de microservicios en el orden de implementación determinado en el Paso 3
4. Luego los documentos de features frontend en orden de dependencia (auth primero, siempre)
5. Finalmente el documento de pruebas

## Paso 6 — Crear el directorio de salida

Antes de escribir los archivos, verifica que el directorio `docs/development/` existe. Si no existe, créalo.

---

# REGLAS IMPORTANTES

- NO generar código de aplicación dentro de los documentos de plan. Los documentos describen QUÉ implementar y cómo estructurarlo, no contienen implementaciones completas.
- SÍ incluir fragmentos de código ilustrativos (firmas de métodos, ejemplos de configuración, comandos exactos) cuando sea necesario para claridad.
- Las rutas de archivos en comandos deben ser relativas al directorio raíz del repositorio.
- Los comandos de scaffold deben derivarse del diseño: si un servicio usa Kafka, incluir el flag `-m kafka-producer` o `-m kafka-consumer` según corresponda; si usa PostgreSQL, `-d postgres`; si usa MongoDB, `-d mongo`.
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
