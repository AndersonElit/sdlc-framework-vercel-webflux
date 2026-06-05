# Plan de Incorporación — Apache Camel (Integración + Consumo de APIs Externas) y Patrón Saga (Transacciones Distribuidas)

> Plan de evolución del **SDLC Framework**. No es un artefacto generado por el pipeline: es el plan para modificar el framework (skills, templates, scripts e infraestructura) de modo que **todo proyecto generado** incorpore, de forma trazable y bajo TDD, integración con sistemas externos vía Apache Camel y transacciones distribuidas vía patrón Saga.

---

## 1. Objetivo

Dotar al framework de dos capacidades, propagadas end-to-end por las 7 etapas del pipeline:

1. **Integración con sistemas externos y consumo de APIs externas** mediante **Apache Camel**, concentrada en un **microservicio dedicado** (`integration-service`) que actúa como capa de integración / Anti-Corruption Layer (ACL) y mediador EAI.
2. **Gestión de transacciones distribuidas** mediante el **patrón Saga (orquestación)**, donde el **orquestador vive dentro del mismo `integration-service`** (Camel Saga EIP + coordinador LRA) y los servicios de dominio actúan como **participantes** (outbox + compensaciones).

Ambas capacidades deben quedar **modeladas en el diseño**, **planificadas bajo TDD** y **generadas como código**, sin romper la trazabilidad existente del framework.

---

## 2. Decisión de topología (confirmada)

| Eje | Decisión |
|---|---|
| **Capa de integración (Camel)** | **Microservicio dedicado `integration-service`**. Los servicios de dominio NO hablan con sistemas externos: consumen `integration-service` vía REST/Kafka. |
| **Orquestación de Saga** | **Dentro de `integration-service`** (Camel Saga EIP + LRA). Los servicios de dominio son **participantes**. |
| **Coordinador de saga** | **Narayana LRA** (MicroProfile Long Running Actions), estándar respaldado por Camel Saga. Implementado tras la interfaz `SagaCoordinatorPort`. |

**Consecuencias de diseño:**

- `integration-service` es un **arquetipo de servicio nuevo**, con su propio scaffolder dedicado. Camel está "en su casa": mediación, ACL, resiliencia y orquestación de saga centralizadas.
- Los servicios de dominio se mantienen casi iguales; solo se les añade, **cuando participan en una saga**: módulo **outbox** (publicación confiable de eventos) y **endpoints/consumidores de compensación** idempotentes.
- Esto evita el parcheo frágil del `pom` de cada servicio: la integración es un servicio completo nuevo, no módulos inyectados en servicios existentes.

---

## 3. Encaje en la arquitectura hexagonal

Ni Camel ni LRA se filtran al dominio. Ubicación por capa **dentro de `integration-service`**:

| Elemento | Capa hexagonal | Forma concreta |
|---|---|---|
| Puertos a sistemas externos (`<Sistema>Gateway`) | `domain/model` | Interfaces `Mono`/`Flux`, sin tipos de Camel |
| Puerto coordinador de saga (`SagaCoordinatorPort`) | `domain/model` | Interfaz reactiva, sin tipos de LRA |
| Orquestación de flujos (define pasos y compensaciones) | `application/use-cases` | `SagaOrchestratorUseCase` por flujo; **no conoce** Camel ni LRA |
| Consumo de APIs externas | `infrastructure/driven-adapters/camel-rest-consumer` | Rutas Camel (`camel-http`, `camel-rest`) que implementan los `*Gateway` |
| Coordinación Saga | `infrastructure/driven-adapters/saga-camel` | Implementa `SagaCoordinatorPort` con Camel Saga EIP + cliente LRA |
| Estado de saga (durabilidad) | `infrastructure/driven-adapters/postgres` | `saga_instance`, `saga_step_log` (R2DBC) |
| Comandos/eventos a participantes | `infrastructure/driven-adapters/kafka-producer` | Emite comandos de saga |
| Respuestas de participantes | `infrastructure/entry-points/kafka-consumer` | Consume confirmaciones/fallos |
| Integración entrante no-HTTP (opcional) | `infrastructure/entry-points/camel-routes` | Rutas Camel como entry-point (file/ftp/jms) |
| API interna (ejecutar/consultar saga) | `infrastructure/entry-points/rest-api` | Endpoints REST internos |

**Regla de oro:** Camel, LRA y Kafka viven exclusivamente en `infrastructure`. El dominio y la aplicación solo ven puertos reactivos verificables con `StepVerifier`.

---

## 4. Decisiones arquitectónicas

Se documentarán como `DS-xxx` (Strategic) y `ADR-xxx` (Diseño Técnico).

### 4.1 Apache Camel
- **DA-1 — Bridge reactivo.** Camel↔Reactor vía `camel-reactive-streams` (o `Mono.fromFuture(producerTemplate.asyncSend(...))`). Los puertos siguen exponiendo `Mono`/`Flux`. Prohibido `block()`.
- **DA-2 — Resiliencia en la ruta.** `errorHandler`/`onException` + reintentos con backoff + **Resilience4j** (`camel-resilience4j`: circuit breaker, timeout) por sistema externo.
- **DA-3 — ACL explícito.** Cada sistema externo tiene su sub-paquete con DTOs externos + mapper a tipos del dominio. El dominio nunca expone tipos del externo.

### 4.2 Saga (orquestación en `integration-service`)
- **DA-4 — Orquestación con Camel Saga EIP + Narayana LRA.** El orquestador vive en `integration-service`; el coordinador de transacciones es **Narayana LRA**, accedido tras `SagaCoordinatorPort`. Coreografía Kafka queda disponible como complemento para flujos de bajo acoplamiento, pero el flujo transaccional principal es orquestado.
- **DA-5 — Compensaciones explícitas e idempotentes.** Cada participante expone su compensación (endpoint REST y/o consumidor de evento de compensación). El diseño documenta, por paso, acción y compensación.
- **DA-6 — Transactional Outbox.** En cada participante, los eventos que deban ser atómicos con un cambio de BD se escriben en una tabla `outbox` dentro de la misma transacción R2DBC; un relay publica a Kafka. Resuelve el dual-write.
- **DA-7 — Idempotencia.** Participantes y compensaciones usan `processed_message` + claves de idempotencia (Camel `idempotentConsumer`) para tolerar reentregas.
- **DA-8 — Durabilidad del estado de saga.** `saga_instance`/`saga_step_log` en PostgreSQL del `integration-service` para sobrevivir reinicios.

---

## 5. Impacto por etapa del pipeline

| # | Etapa / Artefacto | Cambio |
|---|---|---|
| 4 | `input-adc-template.md` | Inventario de sistemas externos (protocolo, dirección, SLA, criticidad) y flujos transaccionales que cruzan servicios. |
| 5 | `strategic-design-sdd` | `domain.md`: integraciones como relaciones del context map (ACL) + eventos de compensación. `architecture.md`: `DS-xxx` para `integration-service` y orquestación de saga. |
| 6 | `technical-design-sdd` | Nuevo componente/contenedor `integration-service` en el C4 (entre los servicios de dominio y los sistemas externos); flujo de saga con compensaciones; OpenAPI de endpoints de compensación de participantes; tablas saga/outbox en `schema.sql`; `ADR-xxx`. |
| 7 | `development-plan` | Nuevo documento `03-ms-integration-service.md` (Camel + saga orquestador); en los participantes, secciones de outbox + compensación; `05-tests.md` con contract tests (WireMock) y E2E de saga compensada. |
| Impl. | **Scaffolder nuevo** `integration_service_scaffold.py` | Genera el arquetipo `integration-service` completo. |
| Impl. | `maven_hexagonal_scaffold.py` | Banderas `--outbox` y `--saga-participant` (módulos integrados en generación, sin parcheo posterior). |
| Impl. | `scaffold-all-services.sh` | Banderas para declarar el `integration-service`, sus sistemas externos y los participantes de saga. |
| Impl. | `base-infrastructure-builder.sh` | Coordinador LRA (Narayana) en `floci-net`; WireMock para pruebas. |
| Impl. | `create-all-secrets-dev.sh` | Secretos `EXT_*` (credenciales externas) y `LRA_COORDINATOR_URL` en `integration-service`. |
| Impl. | CI/CD shared library | Stage `runContractTests` (WireMock) para el `integration-service`. |

---

## 6. ¿Hay que modificar `maven_hexagonal_scaffold.py`? (respuesta a la duda pendiente)

Verificado en el código: el `app` (módulo ensamblador) **solo declara dependencia a `rest-api`** (`maven_hexagonal_scaffold.py:668-675`); el `pom` padre fija la lista de `<modules>` (`:511-525`) y el `Dockerfile` hace `COPY` por módulo. Por tanto, **cualquier módulo nuevo debe registrarse en esos tres sitios** para llegar al classpath de runtime.

Conclusión por tipo de cambio:

- **`integration-service` → NO se modifica `maven_hexagonal_scaffold.py`.** Se crea un **scaffolder dedicado** (`integration_service_scaffold.py`) que genera el servicio completo desde cero (reutilizando helpers comunes donde aplique). Al ser un servicio nuevo y completo, no hay que parchear nada de servicios existentes.
- **Outbox / participante de saga → SÍ, modificación acotada de `maven_hexagonal_scaffold.py`.** Se añade `--outbox`/`--saga-participant` para que el módulo `outbox` (y el consumidor de comandos/compensación) se generen **en tiempo de scaffold**, registrándose nativamente en `<modules>`, `Dockerfile` y el `pom` del `app`. Esto es mucho más robusto que un aumentador post-hoc que tendría que editar XML ya generado.

> En resumen: scaffolder **propio** para el `integration-service`; extensión **mínima e inline** del scaffold existente para que los participantes tengan outbox/compensación sin parcheos frágiles.

---

## 7. Scaffolders

### 7.1 Nuevo: `.claude/templates/integration_service_scaffold.py`

Genera el arquetipo `integration-service` completo (estructura hexagonal §3).

```
python3 integration_service_scaffold.py \
  -n integration-service \
  --org <proyecto> \
  --port 8090 \
  --database postgres \                       # estado de saga
  --external-systems buro=BC-01,pasarela=BC-02 \  # sistema=bounded-context
  --saga-flows originacion,desembolso \        # un orquestador por flujo
  --inbound-routes file,jms                    # entry-points Camel opcionales
```

Genera: `domain/model` (puertos `*Gateway`, `SagaCoordinatorPort`), `application/use-cases` (un `SagaOrchestratorUseCase` por `--saga-flows`), `driven-adapters/camel-rest-consumer` (una ruta por `--external-systems`), `driven-adapters/saga-camel`, `driven-adapters/postgres` (estado saga), `driven-adapters/kafka-producer`, `entry-points/rest-api`, `entry-points/kafka-consumer`, `entry-points/app`, y `entry-points/camel-routes` si hay `--inbound-routes`. Edita los tres ambientes Terraform (igual que el scaffold base) y crea repo+push en Gitea (reusa el flujo existente).

### 7.2 Extensión de `maven_hexagonal_scaffold.py`

Nuevas banderas (módulos generados inline, registrados en pom padre + Dockerfile + app pom):

- `--outbox true` → módulo `infrastructure/driven-adapters/outbox` (tabla + `OutboxAdapter` + `OutboxRelay`) y migración `V3__outbox.sql` (`outbox`, `processed_message`).
- `--saga-participant true` → en `entry-points/kafka-consumer`, consumidor de comandos de saga; en `rest-api`, esqueleto de endpoint de compensación idempotente.

### 7.3 `scaffold-all-services.sh`

```bash
bash .claude/scripts/scaffold-all-services.sh \
  --backend originacion-service:postgres:kafka-producer:8081 \
  --saga-participant originacion-service --outbox originacion-service \
  --integration-service "buro=BC-01,pasarela=BC-02" \
  --saga-flows originacion,desembolso \
  ...
```

- `--integration-service "<sistemas>"` → invoca `integration_service_scaffold.py` (paso 4c).
- `--saga-flows <lista>` → flujos a orquestar.
- `--saga-participant <svc>` / `--outbox <svc>` (repetibles) → pasan `--outbox`/`--saga-participant` al scaffold base de ese servicio.

---

## 8. Estructura de directorios (referencia)

**`integration-service` (capa de integración + orquestador de saga):**

```
backend/integration-service/
├── domain/model/        # BuroGateway, PasarelaGateway, SagaCoordinatorPort, eventos
├── application/use-cases/   # OriginacionSagaUseCase, DesembolsoSagaUseCase
├── infrastructure/
│   ├── driven-adapters/
│   │   ├── camel-rest-consumer/   # BuroRouteBuilder, BuroCamelAdapter (impl BuroGateway), dto+mapper (ACL)
│   │   ├── saga-camel/            # SagaRouteBuilder, CamelSagaCoordinatorAdapter (impl SagaCoordinatorPort)
│   │   ├── postgres/              # saga_instance, saga_step_log
│   │   └── kafka-producer/        # comandos de saga a participantes
│   └── entry-points/
│       ├── rest-api/              # ejecutar/consultar saga (API interna)
│       ├── kafka-consumer/        # respuestas de participantes
│       ├── camel-routes/          # (opcional) integración entrante no-HTTP
│       └── app/
```

**Servicio de dominio participante (p. ej. `originacion-service`):**

```
backend/originacion-service/
├── infrastructure/
│   ├── driven-adapters/
│   │   ├── postgres/              # (existente)
│   │   ├── outbox/               # NUEVO — outbox + relay
│   │   └── kafka-producer/        # (existente)
│   └── entry-points/
│       ├── rest-api/              # + endpoint de compensación idempotente
│       └── kafka-consumer/        # + consumidor de comandos de saga
└── db/migration/V3__outbox.sql    # outbox, processed_message
```

---

## 9. Modelo de datos adicional (migraciones Flyway)

- **`integration-service`** (`V1`/`V2` propias del servicio):
  - `saga_instance` — `saga_id (PK)`, `saga_type`, `state`, `current_step`, `payload (jsonb)`, timestamps.
  - `saga_step_log` — `id`, `saga_id (FK)`, `step_name`, `status` (`PENDING|COMPLETED|COMPENSATED|FAILED`), `compensation_payload (jsonb)`, `executed_at`.
- **Participantes** (`V3__outbox.sql`):
  - `outbox` — `id`, `aggregate_type`, `aggregate_id`, `event_type`, `payload (jsonb)`, `topic`, `created_at`, `published_at NULL`, `status`. Índice `(status, created_at)`.
  - `processed_message` — `message_id (PK)`, `consumer`, `processed_at`.

> Regla existente del framework: cada tabla es propiedad de exactamente un microservicio.

---

## 10. Dependencias e infraestructura

### 10.1 Maven (solo `integration-service`, salvo outbox)
- BOM `camel-spring-boot-bom` (alineado a Spring Boot 3.4.x del stack).
- `camel-spring-boot-starter`, `camel-http-starter`, `camel-rest-starter`, `camel-jackson`, `camel-reactive-streams-starter`, `camel-resilience4j-starter`.
- `camel-saga-starter` + `camel-lra-starter`.
- Test: `camel-test-spring-junit5`, `wiremock`.
- Participantes (outbox): sin Camel; solo `spring-kafka` (ya presente) + Testcontainers en test.

### 10.2 Infraestructura local (floci + K3d)
- **Coordinador LRA (Narayana)** en `floci-net`, `localhost:50000` (interno `<proyecto>-lra-coordinator:50000`). `LRA_COORDINATOR_URL` en el secreto del `integration-service`.
- **WireMock** para contract tests de las rutas Camel de salida (contenedor o Testcontainers).
- **Secretos** (`create-all-secrets-dev.sh`): por sistema externo `EXT_<SISTEMA>_BASE_URL` + credenciales; `LRA_COORDINATOR_URL`.

---

## 11. TDD (regla transversal del framework)

| Elemento | Prueba primero (Red) | Herramienta | Implementación (Green) |
|---|---|---|---|
| Puerto `*Gateway` / `SagaCoordinatorPort` | contrato con doble de prueba | JUnit 5 + StepVerifier | interfaz en `domain` |
| `SagaOrchestratorUseCase` | happy path + cada fallo dispara compensaciones N-1…1 | JUnit 5 + Mockito + StepVerifier | use case |
| Adaptador Camel de salida | ruta contra API externa simulada | **WireMock** + `camel-test-spring-junit5` + StepVerifier | RouteBuilder + adaptador |
| Resiliencia (circuit breaker/retry) | fallo/timeout del externo | WireMock (delays/errores) | config Resilience4j |
| Saga (Camel Saga EIP) | saga completa / saga compensada | Camel Saga test | SagaRouteBuilder + adaptador LRA |
| Outbox (participante) | escritura atómica con cambio de BD; relay publica una vez | Testcontainers + embedded Kafka | OutboxAdapter + OutboxRelay |
| Idempotencia | reentrega no produce doble efecto | Testcontainers | `idempotentConsumer` + `processed_message` |
| Endpoint de compensación | contrato HTTP idempotente | WebTestClient | `@RestController`/Router |

Reactivo siempre con **StepVerifier**, nunca `block()`. Umbrales sugeridos: lógica de saga ≥ 85%, adaptadores de integración ≥ 80%.

---

## 12. Cambios concretos por archivo

- **`.claude/formatos/input-adc-template.md`** — sección "Integraciones" (sistemas externos) y "Consistencia transaccional" (flujos saga).
- **`strategic-design-sdd/SKILL.md`** — context map con ACL + eventos de compensación; `DS-xxx` para `integration-service` y orquestación.
- **`technical-design-sdd/SKILL.md`** — `integration-service` como contenedor en el C4 (entre dominio y sistemas externos); flujo de saga con compensaciones; OpenAPI de compensaciones; tablas saga/outbox en `schema.sql`; `ADR-xxx`.
- **`development-plan/SKILL.md`** — generar `03-ms-integration-service.md`; secciones outbox/compensación en participantes; columnas "Sistemas externos" y "Rol en saga" en el mapa de microservicios; contract tests + E2E de saga compensada en `05-tests.md`.
- **Nuevo `.claude/templates/integration_service_scaffold.py`** (§7.1).
- **`.claude/templates/maven_hexagonal_scaffold.py`** — banderas `--outbox` / `--saga-participant` (§7.2).
- **`scaffold-all-services.sh`** — `--integration-service`, `--saga-flows`, `--saga-participant`, `--outbox` (§7.3); paso 4c.
- **`base-infrastructure-builder.sh`** — coordinador LRA + WireMock.
- **`create-all-secrets-dev.sh`** — `EXT_*` y `LRA_COORDINATOR_URL` para `integration-service`.
- **CI/CD shared library** — stage `runContractTests` (WireMock).

---

## 13. Plan de trabajo por fases

> **Estado de ejecución (2026-06-05):** Fases 0–5 **implementadas y verificadas** (sintaxis, generación de scaffolds y wiring de poms/Dockerfile/migraciones). La **Fase 6** (demo end-to-end + ejecución de la saga compensada) queda **pendiente** porque requiere levantar el ambiente local real (floci + K3d + Maven con dependencias Camel) — no es ejecutable sin esa infraestructura. El README ya fue actualizado.

### Fase 0 — Fundamentos (bloqueante)
- [ ] Fijar versión de Camel compatible con Spring Boot 3.4.x (BOM).
- [x] Coordinador de saga decidido: **Narayana LRA**.
- **Criterio:** borradores de `DS-xxx`/`ADR-xxx` listos.

### Fase 1 — Diseño en el pipeline (skills)
- [ ] Actualizar `input-adc-template.md`, `strategic-design-sdd`, `technical-design-sdd`, `development-plan`.
- **Criterio:** regenerar el diseño de un proyecto ejemplo y verificar que `integration-service`, la saga con compensaciones, el outbox y los endpoints de compensación aparecen en system/design/infrastructure, OpenAPI, `schema.sql` y C4.

### Fase 2 — Scaffolder del `integration-service`
- [ ] Implementar `integration_service_scaffold.py` (§7.1) + sus tests.
- **Criterio:** genera un `integration-service` que **compila** (`mvn -q -DskipTests package`) con rutas Camel y módulo saga-camel.

### Fase 3 — Extensión del scaffold base (participantes)
- [ ] `--outbox` / `--saga-participant` en `maven_hexagonal_scaffold.py` (§7.2) + `V3__outbox.sql`.
- **Criterio:** un servicio generado con `--outbox` compila e incluye el módulo registrado en pom padre, Dockerfile y app pom.

### Fase 4 — Integración con scripts e infraestructura
- [ ] Banderas en `scaffold-all-services.sh`; coordinador LRA + WireMock en `base-infrastructure-builder.sh`; secretos `EXT_*`/`LRA_*`.
- **Criterio:** `scaffold-all-services.sh` con las nuevas banderas finaliza con código 0; `integration-service` y participantes compilan.

### Fase 5 — TDD de referencia y CI/CD
- [ ] Tests Red-Green de referencia (Camel+WireMock, saga compensada, outbox+Testcontainers); stage `runContractTests`.
- **Criterio:** pipeline en verde con los nuevos stages; cobertura cumple §11.

### Fase 6 — Validación end-to-end
- [ ] Proyecto demo: `integration-service` + ≥2 participantes + 1 sistema externo, recorriendo las 7 etapas.
- [ ] E2E de saga feliz y saga compensada (fallo provocado en un participante).
- [ ] Actualizar `README.md`.
- **Criterio:** ambas sagas pasan en local (floci + K3d); doc actualizada.

---

## 14. Riesgos

| ID | Riesgo | Impacto | Mitigación |
|---|---|---|---|
| R-1 | Bridge Camel↔Reactor mal hecho bloquea el event loop | Alto | `camel-reactive-streams`; prohibir `block()`; StepVerifier |
| R-2 | `integration-service` se convierte en ESB / god-service con lógica de negocio | Alto | Mantenerlo solo como mediación + orquestación; la lógica vive en los participantes |
| R-3 | Punto único de fallo / cuello de botella (hop extra) | Alto | Escalado horizontal, timeouts/circuit breaker, idempotencia; coreografía para flujos no críticos |
| R-4 | Compatibilidad de versiones Camel ↔ Spring Boot 3.4.x | Alto | Fijar BOM en Fase 0; smoke test de arranque |
| R-5 | Compensaciones no idempotentes → estados inconsistentes | Alto | `processed_message` + claves de idempotencia; tests de reentrega |
| R-6 | Doble publicación de eventos (dual-write) en participantes | Alto | Transactional Outbox obligatorio (DA-6) |
| R-7 | Operar el coordinador LRA en dev | Medio | Contenedor en `floci-net`; documentar arranque/healthcheck |

---

## 15. Decisiones abiertas

| # | Decisión | Recomendación |
|---|---|---|
| 1 | Outbox relay: polling (`@Scheduled`) vs. CDC (Debezium) | Polling en dev; Debezium como evolución para prod |
| 2 | ¿Coreografía Kafka como complemento desde el inicio? | Opt-in por flujo; el principal es orquestado |

> **Resuelto:** coordinador de saga = **Narayana LRA** (ver §2 y DA-4).

---

## 16. Resumen

La integración con sistemas externos y la orquestación de transacciones se concentran en un **microservicio dedicado `integration-service`** (Camel + Saga EIP + LRA), generado por un **scaffolder propio**. Los servicios de dominio se mantienen y solo reciben, cuando participan en una saga, un **outbox** y **compensaciones idempotentes**, generados por una **extensión mínima e inline** del scaffold base (`--outbox`/`--saga-participant`) — sin parcheo frágil de XML. Todo se propaga con trazabilidad desde el ADC y se construye bajo la doctrina TDD del framework.

**Siguiente paso operativo:** completar la Fase 0 (fijar la versión de Camel vía BOM contra Spring Boot 3.4.x) e iniciar la Fase 1 (actualizar las skills de diseño). El coordinador de saga ya está decidido: **Narayana LRA**.
