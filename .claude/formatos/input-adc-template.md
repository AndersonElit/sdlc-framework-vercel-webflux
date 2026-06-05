# Formato de Entrada — Architectural Decision Context (ADC)

Completa este archivo antes de invocar `/strategic-design-sdd`.  
La skill lo leerá junto al SRS para enriquecer las decisiones estratégicas, drivers arquitectónicos y modelo de seguridad.

Invocación con este archivo:

```
/strategic-design-sdd docs/requirements/SRS-[proyecto].md docs/planning/ADC-[proyecto].md
```

Los campos marcados con `*` son obligatorios. El resto son opcionales; omitirlos permite a la skill inferir valores razonables desde el SRS, pero reduce la precisión del resultado.

---

## 1. Identificación

- **Proyecto:** 
- **Versión del ADC:** 
- **Fecha:** 
- **Autor(es):** 

---

## 2. Contexto Tecnológico *

### Stack permitido / mandatorio

Indica tecnologías que el equipo o la organización ya ha definido como obligatorias o permitidas.

| Capa | Tecnología / Herramienta | Estado | Justificación |
|------|--------------------------|--------|---------------|
| Lenguaje backend | | Mandatorio / Preferido / Permitido | |
| Lenguaje frontend | | | |
| Base de datos relacional | | | |
| Base de datos no relacional | | | |
| Mensajería / eventos | | | |
| Autenticación / identidad | | | |
| Monitoreo / observabilidad | | | |
| CI/CD | | | |

### Stack excluido

Tecnologías que NO deben usarse y por qué:

| Tecnología | Motivo de exclusión |
|------------|---------------------|
| | |

---

## 3. Infraestructura y Despliegue *

- **Modelo de despliegue:** (cloud / on-premise / híbrido)
- **Cloud provider:** (AWS / Azure / GCP / ninguno / por definir)
- **Región / residencia de datos:** 
- **Modelo de servicio:** (SaaS / on-premise instalable / white-label / embebido)
- **Entornos requeridos:** (desarrollo / staging / producción / DR)
- **Estrategia de contenedores:** (Docker / Kubernetes / serverless / ninguna / por definir)

---

## 4. Estilo Arquitectónico Preferido *

- **Estilo principal:** (monolito modular / microservicios / serverless / event-driven / SOA / por definir)
- **Justificación:** 
- **Patrón de integración entre componentes:** (REST / gRPC / mensajería asíncrona / mixto)
- **Patrón de acceso a datos:** (repositorio / CQRS / active record / por definir)
- **Si CQRS:** indica la **BD de escritura** (command, p.ej. PostgreSQL normalizado) y la **BD de lectura** (query/read model, p.ej. MongoDB desnormalizado), y la **sincronización** (Transactional Outbox + Kafka). La reportería (sección 14) extrae del **read model**, no de la BD operacional.

---

## 5. Atributos de Calidad y SLAs *

Define las metas de calidad que guiarán los tradeoffs del diseño.

| Atributo | Meta | Prioridad |
|----------|------|-----------|
| Disponibilidad | ej. 99.9% | Alta / Media / Baja |
| Latencia máxima (p95) | ej. < 500ms | |
| Throughput esperado | ej. 1000 req/seg | |
| Usuarios concurrentes pico | | |
| RTO (Recovery Time Objective) | | |
| RPO (Recovery Point Objective) | | |
| Tiempo de build/deploy máximo | | |

---

## 6. Escala y Crecimiento

- **Usuarios activos esperados — lanzamiento:** 
- **Usuarios activos esperados — año 1:** 
- **Usuarios activos esperados — año 3:** 
- **Volumen de datos estimado — año 1:** 
- **Pico de carga estacional o eventos especiales:** (Black Friday / cierre fiscal / etc.)
- **¿Es un MVP o sistema de producción a escala?**

---

## 7. Compliance y Regulaciones *

Indica las regulaciones aplicables. Impacta directamente el modelo de seguridad y los trust boundaries.

| Regulación / Estándar | Aplicable | Notas |
|-----------------------|-----------|-------|
| GDPR | Sí / No / Por verificar | |
| HIPAA | | |
| PCI-DSS | | |
| SOC 2 | | |
| ISO 27001 | | |
| Normativas locales | | |

- **Requisitos de retención de datos:** 
- **Requisitos de auditoría obligatoria:** 
- **Restricciones de exportación de datos:** 

---

## 8. Integraciones y Sistemas Existentes

### Sistemas legados

| Sistema | Tipo | Forma de integración | Estado |
|---------|------|----------------------|--------|
| | | API / DB directa / archivo / webhook | Activo / Deprecar / Reemplazar |

### APIs y servicios de terceros ya definidos

| Servicio / Sistema externo | Proveedor | Propósito | Protocolo | Dirección | SLA / Latencia | Criticidad |
|----------|-----------|-----------|-----------|-----------|----------------|------------|
| | | | REST / SOAP / gRPC / file / ftp / jms / webhook | Saliente (consumo) / Entrante / Bidireccional | ej. p95 < 800ms / 99.5% | Alta / Media / Baja |

### Dependencias de datos

- **Fuentes de datos externas:** 
- **Sistemas que consumen datos de este sistema:** 

### Capa de integración (Apache Camel)

- **¿Centralizar la conectividad con sistemas externos en un microservicio dedicado `integration-service` (capa de integración / ACL con Apache Camel)?** (sí / no / por definir)
- **Justificación:** (gobierno central de credenciales/SLAs, dominio limpio, mediación EAI vs. autonomía de cada servicio)
- **Protocolos de entrada no-HTTP a soportar (si aplica):** (file / ftp / jms / timer / ninguno)

### Estrategia de transacciones distribuidas (Saga)

Completar si existen operaciones de negocio que **abarcan varios microservicios** y deben mantener consistencia (todo-o-nada con compensaciones).

- **¿Hay transacciones que cruzan servicios?** (sí / no / por definir)
- **Estilo de saga preferido:** (orquestación / coreografía / híbrido / por definir)
- **Ubicación del orquestador (si orquestación):** (en `integration-service` / orquestador dedicado / en un servicio de dominio)
- **Coordinador de transacciones:** (Narayana LRA / saga persistida propia / por definir)

| Flujo transaccional | Servicios participantes | Paso(s) que requieren compensación | Criticidad |
|---------------------|-------------------------|-------------------------------------|------------|
| | | | Alta / Media / Baja |

---

## 9. Equipo y Capacidad

- **Tamaño del equipo de desarrollo:** 
- **Perfil dominante:** (seniors / mixto / mayormente juniors)
- **Experiencia con el estilo arquitectónico elegido:** (alta / media / baja / ninguna)
- **Velocidad de entrega esperada:** (sprints de X semanas, N features por sprint)
- **¿Hay equipos externos / outsourcing?**

---

## 10. Presupuesto de Infraestructura

- **Presupuesto mensual de infraestructura (cloud/servidores):** 
- **¿Existe presupuesto para licencias de software comercial?**
- **Restricciones de costo que afecten decisiones de diseño:**

---

## 11. Restricciones Organizacionales

Decisiones ya tomadas que no son negociables y que la skill debe respetar como restricciones fijas:

- 
- 
- 

---

## 12. Decisiones Previas Ya Tomadas

Lista decisiones arquitectónicas o tecnológicas que ya fueron resueltas antes de esta etapa:

| Decisión | Resultado | Quién decidió | Fecha |
|----------|-----------|---------------|-------|
| | | | |

---

## 13. Reportería (opcional)

Completar **solo si el sistema debe generar reportes** (PDF/XLS/CSV) a partir de datos operacionales.
Si se completa, el pipeline materializa el subsistema de reportería: ETL por lotes con Apache Spark
(dos microservicios Scala — extracción/validación y transformación por tipo) y una capa serverless
de formatos (AWS Lambda + EventBridge). La fuente por defecto es el **read model CQRS** (sección 4).

- **¿El sistema requiere generación de reportes?** (sí / no / por definir)
- **Fuente de datos del ETL:** (read model CQRS [MongoDB, default] / BD relacional vía JDBC [proyectos sin CQRS])
- **Disparo del ETL:** (programado/schedule [default] / on-demand por evento de comando / ambos)
- **Persistencia del catálogo de esquemas:** (tabla `report_schema_catalog` en BD / archivo en repo)

### Tipos de reporte

| Tipo de reporte (`reportType`) | Fuente (colección/tabla) | Columnas/esquema esperado | Formatos de salida | Frecuencia / disparo | Volumetría estimada |
|---|---|---|---|---|---|
| ej. `ventas-mensual` | ej. colección `ventas` (read model) | ej. fecha, sucursal, monto, … | PDF / XLS / CSV | ej. mensual programado | ej. 1M filas/mes |
| | | | | | |

---

## 14. Información Adicional

Contexto relevante no cubierto en las secciones anteriores:


