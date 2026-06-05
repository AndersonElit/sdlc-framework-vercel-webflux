# Plan de Incorporación — Sistema de Reportería (ETL Apache Spark + Generación de Formatos con AWS Lambda/EventBridge)

> Plan de evolución del **SDLC Framework**. No es un artefacto generado por el pipeline: es el plan para modificar el framework (skills, templates, scripts e infraestructura) de modo que **todo proyecto que necesite generar reportes** incorpore, de forma trazable y bajo TDD, un subsistema de reportería basado en un **ETL por lotes con Apache Spark** (dos microservicios Scala) y una **capa de generación de formatos serverless** (AWS Lambda + EventBridge para PDF/XLS/CSV).

---

## 0. Fundamento previo — Patrón CQRS a nivel de proyecto (sesión 0)

> **Esta sección es prerrequisito de todo lo demás.** Antes de incorporar la reportería, el framework adopta **CQRS (Command Query Responsibility Segregation)** como patrón de persistencia a nivel de proyecto: separa el **modelo de escritura** (comandos) del **modelo de lectura** (consultas) en **dos bases de datos distintas**, sincronizadas por **eventos de Kafka**. El subsistema de reportería **no apunta a la base de datos operacional**, sino al **read model no relacional**. Esto es lo que hace que el ETL de §2 en adelante extraiga de MongoDB y **no** de PostgreSQL.

### 0.1 Las dos bases de datos

| Eje | **BD de escritura (command side)** | **BD de lectura (query side)** |
|---|---|---|
| **Tecnología** | **PostgreSQL** (relacional) — ya provista por el framework | **MongoDB** (no relacional / documental) — ya provista por el framework |
| **Rol** | Fuente de verdad transaccional. Reciben los **comandos** los servicios de dominio (WebFlux + R2DBC). Modelo **normalizado**, integridad referencial, transacciones ACID. | Réplica desnormalizada **optimizada para consulta y reportería**. Solo lectura para los consumidores; se actualiza por proyección de eventos. |
| **Quién escribe** | Los servicios de dominio, al ejecutar casos de uso de comando. | El **proyector** (read-model updater), al consumir eventos de Kafka. Nadie más escribe aquí. |
| **Quién lee** | Los propios servicios de dominio para validar invariantes/cargar agregados. | Las **queries** de los servicios, el frontend de consulta y, sobre todo, **el subsistema de reportería (ETL Spark MS1)**. |
| **Forma de los datos** | Tablas normalizadas (3FN). | **Documentos desnormalizados** por *vista de lectura* (`read model`), pre-agregados/aplanados para que la consulta y la extracción de reportes no hagan joins costosos. |

### 0.2 Sincronización por eventos de Kafka (write → read)

La BD de lectura es **eventualmente consistente** con la de escritura. La sincronización **reutiliza el patrón Transactional Outbox que el framework ya tiene** (hoy usado para Saga; ver `PLAN-integracion-camel-saga.md`):

```
   Comando ──► Servicio de dominio (WebFlux)
                     │
                     ▼  (una sola transacción atómica)
            ┌─────────────────────────────┐
            │ PostgreSQL (write model)    │
            │  - cambia el agregado       │
            │  - inserta fila en `outbox` │   ◄── Transactional Outbox (atómico con el cambio)
            └─────────────────────────────┘
                     │  relay/CDC del outbox
                     ▼
                   Kafka  (topics de eventos de dominio: <agregado>.changed, …)
                     │
                     ▼
            Proyector / read-model updater (consumidor)
                     │  upsert idempotente del documento
                     ▼
            ┌─────────────────────────────┐
            │ MongoDB (read model)        │  ◄── aquí apunta la reportería (ETL Spark MS1)
            └─────────────────────────────┘
```

- **Atomicidad:** el cambio en PostgreSQL y la fila en `outbox` ocurren en la **misma transacción**; el relay publica a Kafka después. No hay *dual write*.
- **Proyección idempotente:** el proyector hace **upsert por clave de agregado** (idempotente por `eventId`/versión), de modo que reentregas de Kafka no corrompen el read model.
- **Consistencia eventual:** la reportería tolera el desfase write→read; los eventos `report.*` (§6) ya llevan `validatedAt`/`processedAt` y la idempotencia por `reportId` (DR-3) convive con la del read model.

### 0.3 La reportería apunta al read model (consecuencia clave)

El ETL Spark de §2 extrae **exclusivamente de la BD de lectura no relacional (MongoDB)**, nunca de PostgreSQL:

- **Aislamiento de carga:** los *jobs* Spark por lotes (potencialmente pesados, §14 R-2) **no tocan la BD operacional**; no compiten por conexiones ni bloqueos con el camino de escritura.
- **Lectura óptima:** los documentos del read model ya están **desnormalizados** para consulta, así que MS1 extrae con menos transformación previa y MS2 trabaja sobre datos más cercanos al formato lógico del reporte.
- **Esquema declarado (DR-1) sigue aplicando:** MS1 valida el documento/colección de lectura contra el `ReportSchema` declarado igual que validaría una tabla; lo que cambia es la **fuente** (colección Mongo), no la doctrina de validación.

### 0.4 Decisiones (se documentan en el pipeline)

- **DS-CQRS-1 — Segregación de modelos.** Escritura en PostgreSQL (normalizado, ACID); lectura en MongoDB (desnormalizado, por vista). Ningún consumidor de consulta lee de PostgreSQL.
- **DS-CQRS-2 — Sincronización por outbox + Kafka.** El write model publica eventos de dominio vía **Transactional Outbox** (atómico); un **proyector** materializa el read model. Sin *dual write*.
- **DS-CQRS-3 — La reportería es consumidor del read model.** El ETL Spark (MS1) lee MongoDB; **prohibido** que apunte a PostgreSQL. Decisión arquitectónica que aísla la carga analítica de la operacional.
- **ADR-CQRS-x (Diseño Técnico) — Consistencia eventual aceptada.** Se documenta el desfase write→read tolerable y la idempotencia del proyector; los reportes reflejan el read model en el momento de extracción (`validatedAt`).

### 0.5 Impacto en el pipeline (resumen; se detalla en §5)

| Etapa | Cambio que introduce CQRS |
|---|---|
| 4 — ADC | Declarar **estrategia de persistencia CQRS**: agregados con read model, eventos de sincronización y colecciones de lectura que alimentan cada `reportType`. |
| 5 — Strategic Design | `DS-CQRS-1..3` en `architecture.md`; eventos de proyección (`<agregado>.changed`) en `domain.md`; el read model como vista del bounded context. |
| 6 — Technical Design | C4 con **PostgreSQL (write)** + **MongoDB (read)** + **proyector**; `schema.sql` (write) y `collections.js` (read model) en el modelo de datos; topics de proyección documentados; `ADR-CQRS-x`. |
| 7 — Development Plan | El `01-databases.md` cubre **ambas** BD y la migración del read model; documento/sección del **proyector** (read-model updater) bajo TDD; el ETL de reportería declara su **fuente = colección de lectura**. |
| Impl. | `init-databases.sh` ya crea PostgreSQL **y** MongoDB; se añade el proyector y las colecciones de lectura; el scaffold del ETL usa el **adaptador de origen Mongo** (no JDBC) por defecto (§7.1, §8). |

> **Nota de compatibilidad:** un proyecto **sin** CQRS puede seguir extrayendo directamente de la BD relacional con el adaptador JDBC (configurable, §7.1 `--source jdbc`). El **default del framework** pasa a ser `--source mongo` (read model), coherente con DS-CQRS-3.

---

## 1. Objetivo

Dotar al framework de una capacidad **opt-in y trazable end-to-end** para producir reportes a partir de datos operacionales, propagada por las 7 etapas del pipeline:

1. **ETL por lotes con Apache Spark** concentrado en **dos microservicios Scala** generados con el scaffold `scala_hexagonal_scaffold.py`:
   - **`report-extraction-service` (MS1)** — extrae datos de la **BD de lectura no relacional (read model, MongoDB)** —no de la BD operacional de escritura, ver §0—, los **valida contra un esquema declarado** (columnas e integridad), materializa un `.parquet` **crudo validado** en almacenamiento de objetos (S3) y publica un evento en Kafka.
   - **`report-processing-service` (MS2)** — consume el evento de MS1, lee el `.parquet` de S3, **transforma la información según el tipo de reporte**, materializa un `.parquet` **listo para pintar** en S3 y publica un evento.
2. **Generación de formatos serverless** mediante **AWS Lambda + EventBridge**: un *Lambda Kafka Consumer* consume el evento de MS2 y lo enruta por **EventBridge** a la lambda de formato correspondiente (**PDF / XLS / CSV**).

El subsistema completo debe quedar **modelado en el diseño**, **planificado bajo TDD** y **generado como código** (scaffolders + Terraform), sin romper la trazabilidad existente del framework.

---

## 2. Arquitectura de referencia

```
                 ┌───────────────────────────── ETL Apache Spark (batch, Scala) ─────────────────────────────┐
                 │                                                                                            │
   Read model    │   report-extraction-service (MS1)              report-processing-service (MS2)            │
   MongoDB ─────►│   - lee colección de lectura (CQRS, §0)        - consume report.extracted                 │
   (no PostgreSQL)│  - valida esquema (columnas + integridad)     - lee parquet crudo de S3                  │
                 │   - escribe parquet crudo ─► S3 (raw/)         - transforma por tipo de reporte            │
                 │   - publica report.extracted (Kafka) ─────────►- escribe parquet listo ─► S3 (processed/) │
                 │                                                - publica report.processed (Kafka) ────────┐│
                 └────────────────────────────────────────────────────────────────────────────────────────┼┘
                                                                                                            │
                                                                                                            ▼
                                                                                          Lambda Kafka Consumer
                                                                                            (consume report.processed)
                                                                                                            │
                                                                                                            ▼
                                                                                                       EventBridge
                                                                                                            │
                                                                          ┌─────────────────────────────────┼─────────────────────────────────┐
                                                                          ▼                                 ▼                                 ▼
                                                                      PDF Rule ──► PDF Lambda          XLS Rule ──► XLS Lambda          CSV Rule ──► CSV Lambda
                                                                          │                                 │                                 │
                                                                          └────────────► S3 output/{pdf,xls,csv}/ ◄──────────────────────────┘
```

### 2.1 Decisiones de topología (confirmadas)

| Eje | Decisión |
|---|---|
| **Fuente de datos (CQRS)** | **BD de lectura no relacional = MongoDB (read model)**, sincronizada desde PostgreSQL por eventos Kafka (§0). MS1 lee de aquí; **nunca** de la BD de escritura. Adaptador de origen por defecto = Mongo (`--source mongo`); JDBC queda como alternativa para proyectos sin CQRS. |
| **Motor ETL** | **Apache Spark 3.5.1 (batch)** sobre Scala 2.13, ejecutado como *fat JAR* (`sbt assembly`) — reusa el arquetipo de `scala_hexagonal_scaffold.py`. |
| **Separación de responsabilidades** | **Dos servicios**: MS1 (extracción + **validación de esquema**) y MS2 (**transformación por tipo de reporte**). MS1 no conoce el formato final; MS2 no conoce la BD origen. |
| **Mensajería entre servicios** | **Kafka** (ya provisto por el framework). Topics: `report.extracted` (MS1→MS2) y `report.processed` (MS2→capa serverless). |
| **Almacenamiento de artefactos** | **S3**: `raw/` (parquet crudo validado), `processed/` (parquet listo), `output/{pdf,xls,csv}/` (formatos finales). En dev: **S3 de floci** (`http://floci:4566`); en staging/prod: **S3 real**. |
| **Emulación AWS en dev** | **floci** — el emulador AWS del framework ya levantado en `floci-net` (`floci/floci:latest`, puerto `4566`) por `base-infrastructure-builder.sh`. Provee **S3**, **Lambda** (Docker-backed, ejecución real) y **EventBridge** (buses/rules con *targets* Lambda) de forma nativa; mismo endpoint para AWS SDK/CLI/Terraform. |
| **Generación de formatos** | **Serverless**: *Lambda Kafka Consumer* → **EventBridge** (una *rule* por formato) → **PDF/XLS/CSV Lambda**. Una lambda por formato, desacopladas y escalables. |
| **Disparo de MS1** | Por defecto **programado** (schedule) y/o **on-demand** vía evento de comando; configurable por proyecto. |

**Consecuencias de diseño:**

- Los dos servicios Spark son **arquetipos batch nuevos**, generados con `scala_hexagonal_scaffold.py` (extendido con un rol de reportería). No son servicios de dominio reactivos: son *jobs* por lotes.
- La capa de formatos es **serverless y AWS-nativa** (Lambda + EventBridge); en dev se ejecuta sobre **floci** (Lambda Docker-backed + EventBridge en `:4566`), sin emuladores adicionales, y en staging/prod sobre AWS real con el **mismo Terraform** (floci es drop-in para Terraform/AWS SDK). Se omite con una bandera. Esto evita acoplar la generación de PDF/XLS/CSV a los servicios JVM de dominio.
- El subsistema es **autónomo**: cualquier sistema que "necesite reportes" lo declara en el ADC y el pipeline lo materializa, sin parchear los servicios de dominio existentes.

---

## 3. Encaje en la arquitectura hexagonal (servicios Spark)

Spark, Kafka y S3 **no se filtran al dominio**. Ubicación por capa dentro de cada servicio (reusa la estructura de `scala_hexagonal_scaffold.py`: `domain/model`, `application/use-cases`, `infrastructure/driven-adapters`, `infrastructure/entry-points`):

| Elemento | Capa hexagonal | Forma concreta |
|---|---|---|
| Esquema declarado del reporte (`ReportSchema`, `ColumnSpec`, reglas de integridad) | `domain/model` | *case classes* + invariantes, sin tipos de Spark |
| Puertos de datos (`SourceDataPort`, `ParquetStorePort`, `EventBusPort`) | `domain/model/ports` | Interfaces puras (firmas con tipos del dominio, no `DataFrame`) |
| Validación de esquema (MS1) | `application/use-cases` | `ValidateAndExtractUseCase` — compara columnas + integridad contra `ReportSchema` |
| Transformación por tipo de reporte (MS2) | `application/use-cases` | `ProcessReportUseCase` orquesta; una **factory** (`ReportTransformerFactory`) resuelve el `ReportTransformer` concreto según `reportType` (ver DR-10) |
| Transformadores concretos por reporte (MS2) | `application/use-cases/transformers` | Una implementación de `ReportTransformer` por tipo de reporte (`VentasMensualTransformer`, …) registrada en la factory |
| Lectura del read model (BD de lectura CQRS) | `infrastructure/driven-adapters/mongo-source` | `SparkMongoSourceAdapter` (`mongo-spark-connector`) implementa `SourceDataPort`, leyendo la colección de lectura (§0). `SparkJdbcSourceAdapter` (Spark JDBC) queda como adaptador alterno para proyectos sin CQRS. |
| Lectura/escritura de parquet en S3 | `infrastructure/driven-adapters/s3-parquet` | `SparkS3ParquetAdapter` (`hadoop-aws`) implementa `ParquetStorePort` |
| Publicación de eventos | `infrastructure/driven-adapters/kafka-producer` | `KafkaEventPublisher` implementa `EventBusPort` |
| Consumo de evento (MS2) | `infrastructure/entry-points/kafka-consumer` | Dispara `ProcessReportUseCase` al recibir `report.extracted` |
| Arranque del job batch | `infrastructure/entry-points` | `BatchMain` (ya existe en el scaffold) cablea puertos→adaptadores y ejecuta el use case |

**Regla de oro:** `DataFrame`, `SparkSession`, clientes Mongo/S3/Kafka viven **exclusivamente** en `infrastructure`. El dominio y la aplicación solo ven puertos verificables con dobles de prueba (`SparkSession` local en tests de adaptadores).

---

## 4. Decisiones arquitectónicas

Se documentarán como `DS-xxx` (Strategic) y `ADR-xxx` (Diseño Técnico).

### 4.1 ETL Spark
- **DR-1 — Esquema declarativo como contrato.** El esquema de cada reporte (columnas, tipos, nulabilidad, reglas de integridad referencial/rango) se declara como dato del dominio y es la **fuente de verdad** de la validación de MS1. Validación fallida ⇒ el job **falla rápido** y publica `report.extraction.failed`.
- **DR-2 — Parquet como contrato entre etapas.** El intercambio MS1→MS2 es un `.parquet` en `raw/` con esquema versionado; MS2 nunca vuelve a la BD origen. MS2 produce `processed/` listo para pintar (una fila ≈ una celda lógica del formato).
- **DR-3 — Idempotencia por `reportId` + partición.** Cada ejecución usa un `reportId` (y `runId`) que define la ruta en S3 (`raw/<reportType>/<reportId>/`) y la clave del evento; reprocesos sobrescriben de forma determinista.
- **DR-4 — Spark `provided` en runtime, embebido en tests.** Dependencias Spark `% "provided"` en domain/use-cases/driven-adapters (como ya hace el scaffold) y `SparkSession` local (`local[*]`) en los entry-points y en los tests.
- **DR-10 — Factory de transformadores en MS2 (obligatorio).** La transformación por tipo de reporte se resuelve con el **patrón Factory**, no con condicionales. Elementos:
  - **Puerto/trait `ReportTransformer`** (`application/use-cases`): contrato común `def transform(raw: DataFrame): DataFrame` (firma con tipos del dominio en la frontera; `DataFrame` solo como detalle de la transformación Spark). Cada tipo de reporte implementa este trait con su lógica de agregación/pivot/formato lógico.
  - **`ReportTransformerFactory`**: dado un `ReportType` devuelve el `ReportTransformer` correspondiente. Mantiene un **registro** `Map[ReportType, ReportTransformer]` (poblado en el cableado de `BatchMain`), de modo que **añadir un nuevo tipo de reporte = añadir una clase + registrarla**, sin tocar `ProcessReportUseCase` (principio Abierto/Cerrado).
  - **`ProcessReportUseCase`** depende de la factory, no de los transformadores concretos: pide el transformer por `reportType`, lo aplica al parquet `raw/` y escribe `processed/`. Si el `reportType` no está registrado ⇒ falla con `UnsupportedReportTypeException` y publica `report.processing.failed`.
  - **Aislamiento hexagonal:** la factory y los transformers viven en `application/use-cases`; no conocen Kafka, S3 ni Spark de infraestructura (solo el `DataFrame` que reciben). Esto los hace verificables con `SparkSession` local y *fixtures* de parquet.

### 4.2 Capa serverless de formatos
- **DR-5 — Desacople por EventBridge.** El *Lambda Kafka Consumer* solo traduce el evento Kafka `report.processed` a un evento de EventBridge; **no** genera formatos. El enrutamiento por formato es responsabilidad de las *rules* (`detail.format = PDF|XLS|CSV`).
- **DR-6 — Una lambda por formato.** PDF/XLS/CSV son lambdas independientes (despliegue, escalado y dependencias aislados). Cada una lee el `processed/` parquet y escribe en `output/<formato>/`.
- **DR-7 — Fan-out multi-formato.** Si un reporte requiere varios formatos, el evento lleva una lista; EventBridge hace *fan-out* a varias rules simultáneamente.
- **DR-8 — floci como AWS en dev.** En dev, S3/Lambda/EventBridge corren sobre **floci** (`http://floci:4566` interno / `http://localhost:4566` host), ya presente en `floci-net`; en staging/prod son servicios AWS reales. Como floci es **drop-in** (AWS SDK/CLI/Terraform apuntan al mismo endpoint), el código de las lambdas y el Terraform son idénticos entre dev y prod (solo cambia `AWS_ENDPOINT_URL`). Bandera `ENABLE_REPORTING_SERVERLESS` para omitir.
- **DR-9 — Puente Kafka→EventBridge.** El *Lambda Kafka Consumer* (DR-5) traduce `report.processed` a EventBridge. floci soporta además **EventBridge Pipes** con fuente MSK; queda como alternativa nativa para sustituir el consumer por un *pipe* MSK→EventBridge si se adopta MSK en lugar del contenedor Kafka actual (ver §14, decisión 4).

---

## 5. Impacto por etapa del pipeline

| # | Etapa / Artefacto | Cambio |
|---|---|---|
| 4 | `input-adc-template.md` | Nueva sección **"Reportería"**: tipos de reporte, fuentes de datos, esquema/columnas esperadas, formatos de salida (PDF/XLS/CSV), frecuencia/disparo y volumetría. |
| 5 | `strategic-design-sdd` | `domain.md`: **bounded context de Reportería** (lenguaje ubicuo: `ReportSchema`, `ReportType`, eventos `ReportExtracted`/`ReportProcessed`). `architecture.md`: `DS-xxx` para el ETL Spark de dos etapas y la capa serverless de formatos. |
| 6 | `technical-design-sdd` | Contenedores `report-extraction-service`, `report-processing-service` y la malla serverless (Lambda consumer, EventBridge, PDF/XLS/CSV) en el **C4**; flujo ETL en `design.md`; esquemas parquet (`raw`/`processed`) y la tabla de catálogo de esquemas en `schema.sql`; eventos en OpenAsyncAPI/documentación de topics; `ADR-xxx`. |
| 7 | `development-plan` | Nuevos documentos `03-ms-report-extraction-service.md` y `03-ms-report-processing-service.md` (capas hexagonales Spark, TDD); documento `06-reporting-serverless.md` (lambdas + EventBridge); columnas "Tipo de reporte" y "Formatos" en el mapa de servicios; E2E de reportería en `05-tests.md`. |
| Impl. | **Scaffold Scala** `scala_hexagonal_scaffold.py` | Rol de reportería (`--report-role extraction|processing`, `--source mongo|jdbc`) + adaptadores Mongo(read model)/S3-parquet/Kafka y entry-point kafka-consumer; **ediciones de código detalladas en §7.1.1**. |
| Impl. | **Scaffolder nuevo** `report_lambdas_scaffold.py` | Genera las lambdas (Kafka consumer + PDF/XLS/CSV) y el Terraform de EventBridge/rules (§7.2). |
| Impl. | `scaffold-all-services.sh` | Banderas `--report-extraction`, `--report-processing`, `--report-formats pdf,xls,csv` (§7.3). |
| Impl. | `base-infrastructure-builder.sh` | Buckets S3 en **floci**, topics Kafka de reportería, bus EventBridge + Lambdas en **floci** (`floci/floci:latest` ya levantado en `floci-net`); sin contenedores de emulación extra. |
| Impl. | `init-databases.sh` | Tabla de catálogo `report_schema_catalog` (opcional, si el esquema se persiste en BD). |
| Impl. | `create-all-secrets-dev.sh` | Secretos `S3_*` (endpoint/keys), `REPORT_BUCKET`, `KAFKA_*` y, para lambdas, `EVENTBRIDGE_BUS`. |
| Impl. | CI/CD shared library | Stage `assembly` (fat JAR Spark) y empaquetado/deploy de lambdas para los servicios de reportería. |

---

## 6. Eventos y contratos

### 6.1 `report.extracted` (MS1 → MS2, Kafka)
```json
{
  "reportId": "uuid",
  "runId": "uuid",
  "reportType": "ventas-mensual",
  "schemaVersion": "v1",
  "rawParquetUri": "s3://<proyecto>-reports/raw/ventas-mensual/<reportId>/",
  "rowCount": 12345,
  "validatedAt": "2026-06-05T10:00:00Z"
}
```

### 6.2 `report.processed` (MS2 → Lambda Kafka Consumer, Kafka)
```json
{
  "reportId": "uuid",
  "runId": "uuid",
  "reportType": "ventas-mensual",
  "processedParquetUri": "s3://<proyecto>-reports/processed/ventas-mensual/<reportId>/",
  "formats": ["PDF", "XLS", "CSV"],
  "processedAt": "2026-06-05T10:02:00Z"
}
```

### 6.3 Evento EventBridge (Lambda Consumer → rules)
- `source`: `<proyecto>.reporting`
- `detail-type`: `ReportFormatRequested`
- `detail`: `{ reportId, processedParquetUri, format }` (un evento por formato del array; fan-out por `detail.format`).

### 6.4 Evento de fallo
- `report.extraction.failed` / `report.processing.failed` con `reportId`, `stage`, `reason`, `failedColumns[]` (para validación de esquema).

---

## 7. Scaffolders

### 7.1 Extensión de `scala_hexagonal_scaffold.py`

Hoy genera un único arquetipo batch genérico (`BatchMain`, módulos `domain/use-cases/driven-adapters/entry-points`, `hadoop-aws` ya presente). Se añade un **rol de reportería**:

```bash
python3 scala_hexagonal_scaffold.py \
  --service-name report-processing-service \
  --report-role processing \           # extraction | processing
  --source mongo \                      # solo extraction: mongo (read model, default) | jdbc
  --kafka-in report.extracted \         # solo processing: topic a consumir
  --kafka-out report.processed \        # topic a publicar
  --report-types ventas-mensual,saldos  # solo processing: genera un transformer + registro por tipo
```

- `--report-role extraction` → genera: puerto `ReportSchema`/`SourceDataPort`, `ValidateAndExtractUseCase`, el adaptador de origen según `--source` (**`driven-adapters/mongo-source`** con `mongo-spark-connector` por defecto —lee el read model CQRS, §0—; `driven-adapters/jdbc-source` con Spark JDBC si `--source jdbc`), `driven-adapters/s3-parquet` (escribe `raw/`), `driven-adapters/kafka-producer`; `BatchMain` cablea lectura del read model → validación → parquet → publica `report.extracted`.
- `--report-role processing` → genera el esqueleto del **patrón Factory** (DR-10): el trait `ReportTransformer`, la `ReportTransformerFactory` con su registro, un `ProcessReportUseCase` que delega en la factory, y **una clase transformer por cada `--report-types`** (`VentasMensualTransformer`, `SaldosTransformer`, …, con un `transform` a implementar) ya **registrada** en `BatchMain`. Además: `driven-adapters/s3-parquet` (lee `raw/`, escribe `processed/`), `driven-adapters/kafka-producer`, `entry-points/kafka-consumer` (consume `report.extracted` y dispara el job); `BatchMain` en modo *triggered-by-event*. Añadir un tipo nuevo después = `--report-types` regenera el esqueleto, o se crea la clase a mano y se registra (sin tocar el use case).

Adiciones al `build.sbt` generado (sobre lo ya existente): `spark-sql` JDBC (incluido), dependencia Kafka cliente (p. ej. `kafka-clients` para el publisher, y para el consumer en MS2). Mantiene Spark `% "provided"` y el bloque de `--add-opens` ya presente.

#### 7.1.1 Ediciones concretas a `scala_hexagonal_scaffold.py`

El script actual (239 líneas) genera un único arquetipo batch genérico: `main()`→`scaffold()` invoca `build_files`, `dotenv_files`, `domain_model`, `application_use_cases`, `driven_adapters`, `entry_points`. Hoy `domain_model`/`application_use_cases`/`driven_adapters` solo escriben `.gitkeep` y `entry_points` emite un `BatchMain` con un `run()` vacío. Las ediciones convierten esos *placeholders* en generadores reales **cuando se pasa `--report-role`** (sin `--report-role`, el comportamiento genérico actual se conserva intacto — cambio retrocompatible).

**A) `main()` — nuevos argumentos CLI** (en el `argparse`, junto a `--service-name`):

| Argumento | Tipo | Aplica a | Default |
|---|---|---|---|
| `--report-role` | `choices=[extraction, processing]` | dispara todo el modo reportería; si se omite → arquetipo genérico actual | `None` |
| `--source` | `choices=[mongo, jdbc]` | solo `extraction` (fuente CQRS, §0) | `mongo` |
| `--kafka-in` | `str` (topic) | solo `processing` (topic a consumir) | `report.extracted` |
| `--kafka-out` | `str` (topic) | ambos roles (topic a publicar) | `report.extracted` / `report.processed` |
| `--report-types` | `str` (lista CSV) | solo `processing` (un transformer + registro por tipo) | `""` |

**B) `scaffold()` — bifurcación por rol.** Tras calcular `pkg`, si `report_role` está presente, en vez de los generadores genéricos se invocan los nuevos (abajo). `build_files` recibe ahora `report_role`/`source`/`report_types` para inyectar dependencias y módulos.

**C) `build_files()` — `build.sbt` extendido.** Sobre lo existente (Spark `provided`, `hadoop-aws`, `--add-opens`):
- añadir `val kafka = Seq("org.apache.kafka" % "kafka-clients" % "3.7.0")` y sumarlo a `drivenAdapters` (productor) y, en `processing`, a `entryPoints` (consumidor);
- en `extraction` con `--source mongo`: `val mongo = Seq("org.mongodb.spark" %% "mongo-spark-connector" % "10.3.0")` sumado a `drivenAdapters`;
- nuevos sub-módulos sbt para los adaptadores que hoy no existen como proyectos (`mongo-source`/`jdbc-source`, `s3-parquet`, `kafka-producer`, `kafka-consumer`), o mantenerlos dentro de `driven-adapters`/`entry-points` ya declarados (recomendado: reusar los módulos existentes, solo añadiendo paquetes).

**D) Nuevos generadores (funciones nuevas en el script), por rol:**

| Función nueva | Rol | Archivos `.scala` que emite (con cuerpo real, no `.gitkeep`) |
|---|---|---|
| `report_domain_model(root, pkg)` | ambos | `domain/.../model/{ReportSchema, ColumnSpec, ReportType}.scala`; `domain/.../ports/{SourceDataPort, ParquetStorePort, EventBusPort}.scala` (traits con tipos del dominio, sin `DataFrame`) |
| `validate_extract_use_case(root, pkg)` | extraction | `application/.../usecases/ValidateAndExtractUseCase.scala` (compara columnas+integridad contra `ReportSchema`; falla→`report.extraction.failed`) |
| `mongo_source_adapter(root, pkg)` / `jdbc_source_adapter(...)` | extraction | `infrastructure/driven/{mongosource/SparkMongoSourceAdapter, jdbcsource/SparkJdbcSourceAdapter}.scala` (implementa `SourceDataPort`; Mongo por default) |
| `s3_parquet_adapter(root, pkg, mode)` | ambos | `infrastructure/driven/s3parquet/SparkS3ParquetAdapter.scala` (escribe `raw/` en extraction; lee `raw/`+escribe `processed/` en processing) |
| `kafka_producer_adapter(root, pkg, topic)` | ambos | `infrastructure/driven/kafkaproducer/KafkaEventPublisher.scala` (implementa `EventBusPort`) |
| `kafka_consumer_entry_point(root, pkg, topic_in)` | processing | `infrastructure/entrypoints/kafkaconsumer/ReportProcessedConsumer.scala` (consume `--kafka-in`, dispara el job) |
| `report_transformer_factory(root, pkg, types)` | processing | `application/.../usecases/{ReportTransformer.scala (trait), ReportTransformerFactory.scala}` + `transformers/<Tipo>Transformer.scala` por cada `--report-types`; `ProcessReportUseCase.scala` que delega en la factory (DR-10) |

**E) `entry_points()` — `BatchMain` cableado por rol** (reemplaza el `run()` vacío actual):
- `extraction`: instancia `SourceDataPort`→`ParquetStorePort`→`EventBusPort` y ejecuta `ValidateAndExtractUseCase`; publica `--kafka-out` (`report.extracted`).
- `processing`: cablea la `ReportTransformerFactory` con **todos los `--report-types` registrados**, e invoca `ProcessReportUseCase`; arranca en modo *triggered-by-event* desde el `kafka-consumer`. El `mainClass` sigue siendo `infrastructure.entrypoints.BatchMain` (ya configurado en `build.sbt`).

**F) `dotenv_files()` — variables del subsistema.** Sustituir/ampliar las `R2_*` actuales por las del plan (§10.3): `AWS_ENDPOINT_URL`, `REPORT_BUCKET`, `KAFKA_BOOTSTRAP_SERVERS`, y para `--source mongo`: `MONGO_URI`/`MONGO_READ_DB`/`MONGO_READ_COLLECTION` (read model CQRS).

**G) Mensaje final de `scaffold()`.** Ajustar las instrucciones impresas (hoy mencionan credenciales R2) para reflejar Mongo/S3-floci/Kafka y el comando de corrida del job de reportería.

> **Regla de no-regresión:** sin `--report-role`, `scaffold()` ejecuta exactamente la ruta actual (placeholders `.gitkeep` + `BatchMain` vacío). Toda la lógica nueva queda detrás del flag, de modo que los proyectos Scala existentes generados por el scaffold no cambian. Los archivos nuevos se emiten **al ejecutar** el scaffold con el flag (no hay paso manual posterior salvo implementar el cuerpo de cada `transform`).

### 7.2 Nuevo: `.claude/templates/report_lambdas_scaffold.py`

Genera la **capa serverless de formatos** (handlers + Terraform):

```bash
python3 report_lambdas_scaffold.py \
  --org <proyecto> \
  --formats pdf,xls,csv \
  --kafka-topic report.processed \
  --runtime python3.12              # runtime de las lambdas
```

Genera:
- `reporting-lambdas/kafka-consumer/` — handler que consume `report.processed` (trigger Kafka/MSK o poller) y publica a EventBridge (`PutEvents`, un evento por formato).
- `reporting-lambdas/pdf/`, `.../xls/`, `.../csv/` — un handler por formato: lee `processedParquetUri` (pyarrow/pandas), renderiza (`reportlab` PDF, `openpyxl` XLS, `csv` CSV) y escribe en `output/<formato>/`.
- `infra/` — Terraform: bus EventBridge `<proyecto>-report-bus`, **una rule por formato** (`detail.format = PDF|XLS|CSV`) con *target* Lambda, funciones Lambda, permisos IAM y triggers. **El mismo Terraform** aplica en dev (provider AWS apuntando a floci, `endpoints { ... = "http://localhost:4566" }`) y en staging/prod (AWS real); solo cambian las variables de endpoint/credenciales.

> **Runtime de las lambdas:** Python 3.12 por simplicidad de las librerías de render (pyarrow + reportlab/openpyxl). floci ejecuta Lambda **Docker-backed** (ejecución real, no mock), así que la lambda corre en dev igual que en AWS. Es una **decisión abierta** (§14): podría usarse JVM para reusar lectura de parquet del stack, a costa de cold-start mayor.

### 7.3 `scaffold-all-services.sh`

```bash
bash .claude/scripts/scaffold-all-services.sh \
  --report-extraction report-extraction-service:mongo:report.extracted \
  --report-processing report-processing-service:report.extracted:report.processed \
  --report-types ventas-mensual,saldos \
  --report-formats pdf,xls,csv \
  ...
```

- `--report-extraction <svc>:<source>:<topic-out>` → invoca `scala_hexagonal_scaffold.py --report-role extraction --source <source>` (`mongo` = read model CQRS, default; `jdbc` para proyectos sin CQRS).
- `--report-processing <svc>:<topic-in>:<topic-out>` → invoca `scala_hexagonal_scaffold.py --report-role processing`.
- `--report-types <lista>` → se pasa como `--report-types` al scaffold de MS2: genera un `ReportTransformer` por tipo y los registra en la factory (DR-10).
- `--report-formats <lista>` → invoca `report_lambdas_scaffold.py` (paso serverless), crea repos+push en Gitea y edita los tres ambientes Terraform (reusa el flujo existente).

---

## 8. Estructura de directorios (referencia)

**`report-extraction-service` (MS1 — extracción + validación):**
```
report-extraction-service/
├── domain/model/        # ReportSchema, ColumnSpec, SourceDataPort, ParquetStorePort, EventBusPort
├── application/use-cases/   # ValidateAndExtractUseCase
├── infrastructure/
│   ├── driven-adapters/
│   │   ├── mongo-source/     # SparkMongoSourceAdapter (read model CQRS; jdbc-source alterno)
│   │   ├── s3-parquet/       # SparkS3ParquetAdapter (escribe raw/)
│   │   └── kafka-producer/   # KafkaEventPublisher (report.extracted)
│   └── entry-points/         # BatchMain (lee read model → valida → parquet → publica)
└── build.sbt
```

**`report-processing-service` (MS2 — transformación por tipo de reporte):**
```
report-processing-service/
├── domain/model/        # ReportType, transform specs, ParquetStorePort, EventBusPort
├── application/use-cases/   # ProcessReportUseCase, ReportTransformer (trait), ReportTransformerFactory
│   └── transformers/        # un ReportTransformer concreto por tipo (Factory, DR-10)
├── infrastructure/
│   ├── driven-adapters/
│   │   ├── s3-parquet/       # lee raw/, escribe processed/
│   │   └── kafka-producer/   # KafkaEventPublisher (report.processed)
│   └── entry-points/
│       ├── kafka-consumer/   # consume report.extracted, dispara el job
│       └── BatchMain         # cableado en modo triggered-by-event
└── build.sbt
```

**Capa serverless de formatos:**
```
reporting-lambdas/
├── kafka-consumer/      # consume report.processed → PutEvents EventBridge
├── pdf/                 # parquet → PDF (reportlab) → output/pdf/
├── xls/                 # parquet → XLS (openpyxl) → output/xls/
├── csv/                 # parquet → CSV → output/csv/
└── infra/               # Terraform: bus + rules (PDF/XLS/CSV) + lambdas + IAM
```

---

## 9. Modelo de datos y almacenamiento

### 9.1 S3 (layout de objetos)
```
s3://<proyecto>-reports/
├── raw/<reportType>/<reportId>/        # parquet crudo validado (MS1)
├── processed/<reportType>/<reportId>/  # parquet listo para pintar (MS2)
└── output/
    ├── pdf/<reportType>/<reportId>.pdf
    ├── xls/<reportType>/<reportId>.xlsx
    └── csv/<reportType>/<reportId>.csv
```

### 9.2 Catálogo de esquemas (opcional, si se persiste en BD)
- `report_schema_catalog` — `report_type (PK)`, `schema_version`, `columns (jsonb)`, `integrity_rules (jsonb)`, `updated_at`. Lo consulta MS1 para resolver el `ReportSchema` vigente.

> Regla existente del framework: cada tabla/bucket-prefix es propiedad de exactamente un componente del subsistema de reportería.

---

## 10. Dependencias e infraestructura

### 10.1 Servicios Spark (sbt)
- Spark 3.5.1 (`spark-core`, `spark-sql`) `% "provided"` en domain/use-cases/driven-adapters; embebido en entry-points (ya configurado por el scaffold).
- **`mongo-spark-connector`** (lectura del read model CQRS desde MongoDB, §0); `spark-sql` JDBC queda disponible para el adaptador `--source jdbc` alterno.
- `hadoop-aws` + `aws-java-sdk-bundle` (ya presentes) para S3; en dev se apunta al endpoint S3 de floci con `fs.s3a.endpoint=http://floci:4566` y `fs.s3a.path.style.access=true`.
- Cliente Kafka (`kafka-clients`) para publisher/consumer.
- Test: `sbt` + `SparkSession` local + dobles de los puertos.

### 10.2 Lambdas (serverless)
- Python 3.12: `pyarrow`/`pandas` (lectura parquet), `reportlab` (PDF), `openpyxl` (XLS), `csv` (stdlib).
- IAM mínimo: lectura `processed/`, escritura `output/`, `events:PutEvents`.

### 10.3 Infraestructura local (floci + K3d)
- **AWS emulado = floci** (`floci/floci:latest`, ya levantado en `floci-net`, puerto `4566`). No se añaden MinIO/LocalStack: S3, Lambda y EventBridge se sirven desde el contenedor floci existente.
- **S3 (floci)**: `AWS_ENDPOINT_URL=http://floci:4566` (interno) / `http://localhost:4566` (host); `REPORT_BUCKET`, credenciales AWS dummy (`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`); `fs.s3a.path.style.access=true` para Spark.
- **Kafka**: topics `report.extracted`, `report.processed` sobre el Kafka KRaft del framework (contenedor real en `floci-net`). *Nota:* floci ofrece MSK Docker-backed, pero el framework ya provee Kafka propio; se reutiliza ese.
- **EventBridge + Lambda (floci)**: bus `<proyecto>-report-bus`, rules y funciones provisionadas vía Terraform contra `:4566`; Lambda Docker-backed. Bandera `ENABLE_REPORTING_SERVERLESS=0` para omitir todo el bloque serverless.
- **Secretos** (`create-all-secrets-dev.sh`): `AWS_ENDPOINT_URL`, `REPORT_BUCKET`, `KAFKA_BOOTSTRAP_SERVERS`, `EVENTBRIDGE_BUS` y credenciales AWS dummy.

---

## 11. TDD (regla transversal del framework)

| Elemento | Prueba primero (Red) | Herramienta | Implementación (Green) |
|---|---|---|---|
| Validación de esquema (MS1) | columnas faltantes/sobrantes, tipos e integridad disparan fallo | ScalaTest + DataFrame de prueba | `ValidateAndExtractUseCase` |
| `SourceDataPort` / `ParquetStorePort` | contrato con doble de prueba | ScalaTest | interfaces en `domain` |
| Adaptador S3-parquet | escribe/lee parquet round-trip | `SparkSession` local + **S3 de floci** (o `testcontainers-floci`) | `SparkS3ParquetAdapter` |
| Adaptador de origen (read model CQRS) | lectura de colección de lectura → DataFrame | Testcontainers (MongoDB) + `mongo-spark-connector` | `SparkMongoSourceAdapter` (y `SparkJdbcSourceAdapter` con Testcontainers Postgres para el modo `jdbc`) |
| Publicación de evento | evento bien formado tras éxito/fallo | embedded Kafka | `KafkaEventPublisher` |
| Factory de transformers (MS2) | `reportType` conocido → transformer correcto; desconocido → `UnsupportedReportTypeException` | ScalaTest | `ReportTransformerFactory` |
| Transformer por tipo (MS2) | cada `ReportTransformer` produce el parquet esperado para su tipo | ScalaTest + fixtures parquet | transformer concreto (`VentasMensualTransformer`, …) |
| Orquestación (MS2) | use case pide a la factory y escribe `processed/` | ScalaTest + dobles | `ProcessReportUseCase` |
| Lambda de formato (PDF/XLS/CSV) | parquet de entrada → archivo válido en `output/` | pytest + parquet fixture + **S3 de floci** | handler de formato |
| Lambda Kafka Consumer | evento Kafka → `PutEvents` por cada formato | pytest + **EventBridge de floci** | handler consumer |
| Enrutamiento EventBridge | `detail.format` activa la rule correcta | rules en **floci** (`testcontainers-floci` en CI) | Terraform rules |

Umbrales sugeridos: validación de esquema y use cases ≥ 85%; adaptadores y lambdas ≥ 80%.

---

## 12. Cambios concretos por archivo

- **`.claude/formatos/input-adc-template.md`** — sección "Reportería" (tipos de reporte, fuentes, esquema/columnas, formatos, frecuencia, volumetría).
- **`strategic-design-sdd/SKILL.md`** — bounded context de Reportería en el context map; eventos `ReportExtracted`/`ReportProcessed`; `DS-xxx` para ETL de dos etapas + capa serverless.
- **`technical-design-sdd/SKILL.md`** — contenedores de reportería (MS1, MS2, lambdas, EventBridge) en el C4; flujo ETL en `design.md`; esquemas parquet y `report_schema_catalog` en `schema.sql`; topics/eventos documentados; `ADR-xxx`.
- **`development-plan/SKILL.md`** — generar `03-ms-report-extraction-service.md`, `03-ms-report-processing-service.md` y `06-reporting-serverless.md`; columnas "Tipo de reporte" y "Formatos" en el mapa de servicios; E2E de reportería en `05-tests.md`.
- **`.claude/templates/scala_hexagonal_scaffold.py`** — banderas `--report-role extraction|processing`, `--source mongo|jdbc`, `--kafka-in/out`, `--report-types`; nuevos generadores de dominio/use-cases/adaptadores (Mongo read model, S3-parquet, Kafka) y `BatchMain` cableado por rol. **Ediciones de código función por función en §7.1.1** (retrocompatible: sin `--report-role` no cambia nada).
- **Nuevo `.claude/templates/report_lambdas_scaffold.py`** (§7.2).
- **`scaffold-all-services.sh`** — `--report-extraction`, `--report-processing`, `--report-formats` (§7.3); paso de scaffolding serverless.
- **`base-infrastructure-builder.sh`** — buckets S3 en **floci**, topics Kafka de reportería, bus EventBridge + Lambdas en **floci** (reusa el contenedor `floci` ya levantado; sin emuladores nuevos).
- **`create-all-secrets-dev.sh`** — `S3_*`, `REPORT_BUCKET`, `EVENTBRIDGE_BUS`.
- **CI/CD shared library** — stage `assembly` (fat JAR Spark) y deploy de lambdas para los servicios de reportería.

---

## 13. Plan de trabajo por fases

### Fase 0 — Fundamentos (bloqueante)
- [ ] **CQRS (sesión 0, prerrequisito):** confirmar la separación write (PostgreSQL) / read (MongoDB), el proyector vía Transactional Outbox + Kafka y que la reportería apunta al read model (`DS-CQRS-1..3`). El ETL no arranca hasta que exista la colección de lectura que alimenta cada `reportType`.
- [ ] Fijar versiones: Spark 3.5.1 / Scala 2.13 (ya en el scaffold), `mongo-spark-connector`, runtime de lambdas, BOM AWS.
- [ ] Decidir disparo de MS1 (schedule vs. comando) y persistencia del catálogo de esquemas (BD vs. archivo).
- **Criterio:** borradores de `DS-xxx`/`DS-CQRS-x`/`ADR-xxx` y contratos de evento (§6) listos; read model de referencia disponible.

### Fase 1 — Diseño en el pipeline (skills)
- [ ] Actualizar `input-adc-template.md`, `strategic-design-sdd`, `technical-design-sdd`, `development-plan`.
- **Criterio:** regenerar el diseño de un proyecto ejemplo y verificar que MS1, MS2, las lambdas y EventBridge aparecen en system/design/infrastructure, esquemas parquet, topics y C4.

### Fase 2 — Extensión del scaffold Scala
- [ ] Implementar las ediciones de §7.1.1 en `scala_hexagonal_scaffold.py`: args `--report-role`/`--source`/`--kafka-in`/`--kafka-out`/`--report-types`, bifurcación en `scaffold()`, generadores de dominio/use-cases/adaptadores (Mongo read model, S3-parquet, Kafka), `BatchMain` por rol + tests.
- **Criterio:** ambos servicios generados **compilan** (`sbt compile`) y ensamblan (`sbt assembly`).

### Fase 3 — Scaffolder serverless
- [ ] Implementar `report_lambdas_scaffold.py` (§7.2): handlers PDF/XLS/CSV + consumer + Terraform EventBridge/rules.
- **Criterio:** lambdas empaquetan y el Terraform valida (`terraform validate`) y aplica contra **floci** (`:4566`) en dev con el mismo código que en AWS real.

### Fase 4 — Integración con scripts e infraestructura
- [ ] Banderas en `scaffold-all-services.sh`; buckets/topics/EventBridge en `base-infrastructure-builder.sh`; secretos `S3_*`/`REPORT_BUCKET`/`EVENTBRIDGE_BUS`.
- **Criterio:** `scaffold-all-services.sh` con las nuevas banderas finaliza con código 0; servicios compilan y lambdas empaquetan.

### Fase 5 — TDD de referencia y CI/CD
- [ ] Tests Red-Green de referencia (validación de esquema, S3-parquet round-trip, transformación, lambdas contra **floci** vía `testcontainers-floci`); stages `assembly` + deploy de lambdas.
- **Criterio:** pipeline en verde; cobertura cumple §11.

### Fase 6 — Validación end-to-end
- [ ] Proyecto demo: un `reportType` con fuente JDBC → PDF+XLS+CSV, recorriendo las 7 etapas.
- [ ] E2E feliz (parquet raw→processed→3 formatos en `output/`) y E2E de validación fallida (columna faltante ⇒ `report.extraction.failed`, sin parquet).
- [ ] Actualizar `README.md` con la sección de reportería.
- **Criterio:** ambos flujos pasan en local (floci + K3d), con S3/Lambda/EventBridge servidos por floci; doc actualizada.

---

## 14. Riesgos y decisiones abiertas

| ID | Riesgo | Impacto | Mitigación |
|---|---|---|---|
| R-1 | Cold-start / dependencias pesadas en lambdas de formato | Medio | Lambdas livianas por formato; capas (layers) para libs; o JVM si el SLA lo exige |
| R-2 | Volumetría de datos satura un solo job Spark | Alto | Particionado por `reportType`/fecha; ejecutar en cluster (no solo `local[*]`) en prod |
| R-3 | Deriva entre esquema declarado y datos reales | Alto | Validación estricta en MS1 (DR-1) con `report.extraction.failed` y reporte de columnas |
| R-4 | Divergencia dev (floci) ↔ prod (AWS real) | Bajo/Medio | floci es **drop-in** (mismo Terraform/SDK, Lambda Docker-backed); aun así, smoke test en staging real para cubrir diferencias de IAM/límites |
| R-5 | Reprocesos duplican artefactos en S3 | Medio | Idempotencia por `reportId` + sobrescritura determinista (DR-3) |
| R-6 | Acoplar lógica de negocio a la capa serverless | Medio | Las lambdas solo renderizan; la transformación vive en MS2 |

| # | Decisión abierta | Recomendación |
|---|---|---|
| 1 | Runtime de lambdas: Python vs. JVM | **Python 3.12** (libs de render simples); JVM si el cold-start importa |
| 2 | Disparo de MS1: schedule vs. comando vía evento | Configurable por proyecto; default **schedule** |
| 3 | Catálogo de esquemas: BD (`report_schema_catalog`) vs. archivo en repo | BD para esquemas dinámicos; archivo para estáticos |
| 4 | Puente Kafka→EventBridge: Lambda consumer custom vs. **EventBridge Pipes (MSK source)** | Lambda consumer sobre el Kafka actual; migrar a EventBridge Pipes si se adopta MSK (floci soporta ambos en `:4566`) |

---

## 15. Resumen

El subsistema de reportería se materializa en **dos jobs Spark Scala** generados con `scala_hexagonal_scaffold.py` extendido (`--report-role extraction|processing`): **MS1** valida los datos contra un **esquema declarado** y produce un `.parquet` crudo en S3 publicando `report.extracted`; **MS2** lo transforma según el **tipo de reporte** y produce un `.parquet` listo para pintar publicando `report.processed`. La **generación de formatos** se resuelve **serverless** mediante un **scaffolder propio** (`report_lambdas_scaffold.py`): un *Lambda Kafka Consumer* enruta por **EventBridge** (una *rule* por formato) a las lambdas **PDF/XLS/CSV**, que renderizan a `output/`. Todo se propaga con trazabilidad desde el ADC y se construye bajo la doctrina TDD del framework. En dev, **S3, Lambda y EventBridge se sirven desde floci** —el emulador AWS que el framework ya levanta en `floci-net` (`:4566`)— con Lambda **Docker-backed** y el **mismo Terraform/SDK** que en AWS real, de modo que no se introducen emuladores adicionales y la paridad dev↔prod es alta.

**Siguiente paso operativo:** completar la Fase 0 (fijar runtime de lambdas y modo de disparo de MS1, cerrar los contratos de evento de §6) e iniciar la Fase 1 (actualizar las skills de diseño para que el subsistema de reportería aparezca en todo el pipeline).
