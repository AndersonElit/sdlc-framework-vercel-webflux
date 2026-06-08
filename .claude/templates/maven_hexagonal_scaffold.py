#!/usr/bin/env python3
"""Genera un proyecto base Spring Boot Reactivo multimódulo con arquitectura hexagonal."""

import argparse
import json
import logging
import re
import sys
from pathlib import Path

logger = logging.getLogger(__name__)


def get_yaml_content(project_name: str, database: str, messaging_system: str, port: int = 8080, org: str = "myproject") -> str:
    lines = [
        "spring:",
        "  application:",
        f"    name: {project_name}",
        "  config:",
        f'    import: "aws-secretsmanager:/{org}/${{APP_ENV:dev}}/{project_name}"',
        "  cloud:",
        "    aws:",
        "      region:",
        "        static: us-east-1",
    ]
    if database.lower() == "mongo":
        lines += ["  data:", "    mongodb:", "      uri: ${MONGODB_URI}"]
    else:
        lines += ["  r2dbc:", "    url: ${R2DBC_URL}", "    username: ${DB_USERNAME}", "    password: ${DB_PASSWORD}"]

    if messaging_system.lower() in ("rabbit-producer", "rabbit-consumer"):
        lines += [
            "  rabbitmq:",
            "    host: ${RABBITMQ_HOST}",
            "    port: ${RABBITMQ_PORT}",
            "    username: ${RABBITMQ_USERNAME}",
            "    password: ${RABBITMQ_PASSWORD}",
        ]

    if messaging_system.lower() in ("kafka-producer", "kafka-consumer"):
        lines += [
            "  kafka:",
            "    bootstrap-servers: ${KAFKA_BOOTSTRAP_SERVERS}",
        ]
        if messaging_system.lower() == "kafka-producer":
            lines += [
                "    producer:",
                "      key-serializer: org.apache.kafka.common.serialization.StringSerializer",
                "      value-serializer: org.springframework.kafka.support.serializer.JsonSerializer",
            ]
        else:
            lines += [
                "    consumer:",
                "      group-id: ${KAFKA_CONSUMER_GROUP_ID}",
                "      auto-offset-reset: earliest",
                "      key-deserializer: org.apache.kafka.common.serialization.StringDeserializer",
                "      value-deserializer: org.springframework.kafka.support.serializer.JsonDeserializer",
                "      properties:",
                "        spring.json.trusted.packages: '*'",
            ]

    lines += ["server:", f"  port: ${{SERVER_PORT:{port}}}"]
    lines += [
        "management:",
        "  endpoints:",
        "    web:",
        "      exposure:",
        "        include: health,readiness,liveness,prometheus,info,metrics",
        "  metrics:",
        "    tags:",
        "      application: ${spring.application.name}",
        "      environment: ${APP_ENV:dev}",
    ]
    return "\n".join(lines) + "\n"


def get_dev_yaml_content() -> str:
    return """\
spring:
  cloud:
    aws:
      secretsmanager:
        endpoint: ${SM_ENDPOINT:http://localhost:4566}
      credentials:
        access-key: test
        secret-key: test
"""


def get_secrets_setup_content(project_name: str, database: str, messaging_system: str,
                              port: int = 8080, org: str = "myproject",
                              pg_db_prefix: str = "", mongo_db_prefix: str = "") -> str:
    # Database-per-Service: nombre de BD = <prefix>_<servicio_slug> si hay prefijo,
    # o <servicio_slug> si no. Convención alineada con init-databases.sh y
    # create-all-secrets-dev.sh.
    svc_slug = project_name.replace("-", "_")
    pg_db   = f"{pg_db_prefix}_{svc_slug}" if pg_db_prefix else svc_slug
    mongo_db = f"{mongo_db_prefix}_{svc_slug}" if mongo_db_prefix else svc_slug

    secret: dict = {"SERVER_PORT": str(port)}
    if database.lower() == "mongo":
        secret["MONGODB_URI"] = f"mongodb://${{VPS_IP:-localhost}}:27017/{mongo_db}"
    else:
        secret["R2DBC_URL"] = f"r2dbc:postgresql://${{VPS_IP:-localhost}}:5432/{pg_db}"
        secret["DB_USERNAME"] = org or "appuser"
        secret["DB_PASSWORD"] = "change_me"

    if messaging_system.lower() in ("rabbit-producer", "rabbit-consumer"):
        secret["RABBITMQ_HOST"] = "${VPS_IP:-localhost}"
        secret["RABBITMQ_PORT"] = "5672"
        secret["RABBITMQ_USERNAME"] = "guest"
        secret["RABBITMQ_PASSWORD"] = "guest"

    if messaging_system.lower() in ("kafka-producer", "kafka-consumer"):
        secret["KAFKA_BOOTSTRAP_SERVERS"] = "${VPS_IP:-localhost}:29092"

    if messaging_system.lower() == "kafka-consumer":
        secret["KAFKA_CONSUMER_GROUP_ID"] = f"{project_name}-group"

    secret_json = json.dumps(secret)
    return f"""\
#!/usr/bin/env bash
# Crea (o actualiza) el secret de desarrollo en floci (VPS).
# Requiere que floci esté corriendo en $VPS_IP:4566 (o localhost:4566 por defecto).
# Uso: VPS_IP=192.168.122.50 bash create-secrets-dev.sh

SECRET_NAME="{org}/dev/{project_name}"
ENDPOINT="${{FLOCI_ENDPOINT:-http://localhost:4566}}"
REGION="us-east-1"

if aws --endpoint-url="$ENDPOINT" secretsmanager describe-secret \\
       --secret-id "$SECRET_NAME" --region "$REGION" &>/dev/null; then
    aws --endpoint-url="$ENDPOINT" secretsmanager put-secret-value \\
        --secret-id "$SECRET_NAME" \\
        --secret-string '{secret_json}' \\
        --region "$REGION"
    echo "Secret actualizado: $SECRET_NAME"
else
    aws --endpoint-url="$ENDPOINT" secretsmanager create-secret \\
        --name "$SECRET_NAME" \\
        --secret-string '{secret_json}' \\
        --region "$REGION"
    echo "Secret creado: $SECRET_NAME"
fi
"""


def get_dockerfile_content(database: str, messaging_system: str, port: int = 8080, outbox: bool = False) -> str:
    db_module = "mongo" if database.lower() == "mongo" else "postgres"

    copy_poms = [
        "COPY domain/model/pom.xml domain/model/",
        "COPY application/use-cases/pom.xml application/use-cases/",
        f"COPY infrastructure/driven-adapters/{db_module}/pom.xml infrastructure/driven-adapters/{db_module}/",
        "COPY infrastructure/entry-points/rest-api/pom.xml infrastructure/entry-points/rest-api/",
        "COPY infrastructure/entry-points/app/pom.xml infrastructure/entry-points/app/",
    ]
    if outbox:
        copy_poms.append(
            "COPY infrastructure/driven-adapters/outbox/pom.xml infrastructure/driven-adapters/outbox/"
        )
    if messaging_system.lower() == "rabbit-producer":
        copy_poms.append(
            "COPY infrastructure/driven-adapters/rabbit-producer/pom.xml infrastructure/driven-adapters/rabbit-producer/"
        )
    elif messaging_system.lower() == "rabbit-consumer":
        copy_poms.append(
            "COPY infrastructure/entry-points/rabbit-consumer/pom.xml infrastructure/entry-points/rabbit-consumer/"
        )
    elif messaging_system.lower() == "kafka-producer":
        copy_poms.append(
            "COPY infrastructure/driven-adapters/kafka-producer/pom.xml infrastructure/driven-adapters/kafka-producer/"
        )
    elif messaging_system.lower() == "kafka-consumer":
        copy_poms.append(
            "COPY infrastructure/entry-points/kafka-consumer/pom.xml infrastructure/entry-points/kafka-consumer/"
        )

    copy_poms_str = "\n".join(copy_poms)

    return f"""\
# ── Build stage ────────────────────────────────────────────────────────
FROM maven:3.9-eclipse-temurin-21-alpine AS builder
WORKDIR /app

# Copy pom files first to leverage Docker layer caching for dependencies
COPY pom.xml .
{copy_poms_str}
RUN mvn dependency:go-offline -B --no-transfer-progress

# Copy source and build
COPY . .
RUN mvn clean package -DskipTests --no-transfer-progress

# ── Runtime stage ───────────────────────────────────────────────────────
FROM eclipse-temurin:21-jre-alpine
WORKDIR /app
COPY --from=builder /app/infrastructure/entry-points/app/target/*.jar app.jar
EXPOSE {port}
ENTRYPOINT ["java", "-jar", "app.jar"]
"""


def get_jenkinsfile_content(project_name: str, database: str, org: str = "myproject") -> str:
    """Jenkinsfile declarativo genérico parametrizado por servicio.

    Delega en la Shared Library `jenkins-shared-library` y se mantiene mínimo:
    el mismo pipeline sirve para todos los microservicios cambiando solo los
    parámetros.
    """
    db_type = "mongo" if database.lower() == "mongo" else "postgres"
    # Slug saneado para el path del recurso (debe coincidir con el paquete
    # org.<slug> de la Shared Library: sin guiones ni mayúsculas).
    lib_org = "".join(c for c in org.lower() if c.isascii() and c.isalnum()) or "myproject"

    template = """\
@Library('jenkins-shared-library@main') _

// ───────────────────────────────────────────────────────────────────────────
// Jenkinsfile genérico (backend) — parametrizado por servicio.
// El mismo pipeline sirve para todos los microservicios; solo cambian los
// parámetros, que se resuelven en runtime. La lógica vive en la Shared Library
// (vars/) para mantener este archivo mínimo.
//
// Modelo de agentes: Kubernetes plugin. Todo el pipeline corre en un único pod
// efímero (definido en org/__LIB_ORG__/podBackend.yaml de la Shared Library) en
// el cluster del ambiente: K3s nativo en VPS en dev, EKS en staging/prod. El workspace
// se comparte entre stages sin stash/unstash. El pod usa el ServiceAccount
// 'jenkins-agent': IRSA para kaniko en staging/prod; en dev kaniko empuja al
// Gitea Package Registry (HTTP). El despliegue NO ocurre aquí: este pipeline es CI y su
// frontera con el CD es escribir el nuevo image tag en Git (bumpImageTag). El CD lo hace
// ArgoCD por GitOps (auto-sync en dev/staging; sync manual en prod).
// ───────────────────────────────────────────────────────────────────────────

pipeline {
    agent {
        kubernetes {
            defaultContainer 'maven'
            yaml libraryResource('org/__LIB_ORG__/podBackend.yaml')
        }
    }

    options {
        timestamps()
        disableConcurrentBuilds()
        timeout(time: 60, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '30'))
    }

    parameters {
        string(
            name: 'SERVICE_NAME',
            defaultValue: '__SERVICE_NAME__',
            description: 'Nombre del microservicio (deriva el repo en Gitea Package Registry y el deployment).'
        )
        choice(
            name: 'DEPLOY_ENV',
            choices: ['dev', 'staging', 'prod'],
            description: 'Ambiente destino del despliegue.'
        )
    }

    environment {
        SERVICE_NAME  = "${params.SERVICE_NAME}"
        DEPLOY_ENV    = "${params.DEPLOY_ENV}"
        IMAGE_REPO    = "${params.SERVICE_NAME}"
        K8S_NAMESPACE = "${params.DEPLOY_ENV}"
        DB_TYPE       = '__DB_TYPE__'
    }

    stages {
        // 1 — Checkout + metadatos de versión/SHA → IMAGE_TAG inmutable.
        stage('Checkout') {
            steps {
                checkout scm
                script {
                    env.IMAGE_TAG = computeImageTag()
                    echo "IMAGE_TAG=${env.IMAGE_TAG}"
                }
            }
        }

        // 2 — Build + unit tests respetando la regla de dependencias hexagonal.
        stage('Build & Unit Tests') {
            steps { buildBackendService() }
        }

        // 3 — Tests de integración (R2DBC/Mongo/Kafka) con Testcontainers.
        //     Usa el sidecar dind del pod (DOCKER_HOST) para levantar contenedores.
        stage('Integration Tests') {
            steps { runIntegrationTests(dbType: env.DB_TYPE) }
        }

        // 3b — Contract tests de integraciones externas (WireMock). Solo aplica al
        //      integration-service (capa Camel); se detecta por el módulo camel-rest-consumer.
        stage('Contract Tests') {
            when { expression { fileExists('infrastructure/driven-adapters/camel-rest-consumer') } }
            steps { runContractTests() }
        }

        // 4 — Análisis estático + quality gate (SonarQube). Falla si gate = ERROR.
        stage('Quality Gate (SonarQube)') {
            steps { runQualityGates() }
        }

        // 5 — OWASP Dependency Check + escaneo de secretos (gitleaks).
        stage('Security Scans') {
            steps { runSecurityScans() }
        }

        // 6 — Imagen Docker multi-stage vía Kaniko → push a Gitea Package Registry.
        stage('Build & Push Image') {
            steps {
                buildAndPushImage(
                    service:   env.SERVICE_NAME,
                    imageRepo: env.IMAGE_REPO,
                    imageTag:  env.IMAGE_TAG
                )
            }
        }

        // 7 — Escaneo de la imagen publicada (Trivy). Falla ante CVE crítico.
        stage('Image Scan (Trivy)') {
            steps { scanImage(imageRepo: env.IMAGE_REPO, imageTag: env.IMAGE_TAG) }
        }

        // 8 — Frontera CI → CD. Escribe image.repository/tag en
        //     helm/<service>/values-<env>.yaml y commitea (GitOps). NO despliega:
        //     ArgoCD detecta el commit y sincroniza el cluster. La aprobación de
        //     prod ya no vive aquí, sino como sync manual en la UI de ArgoCD.
        stage('Update GitOps (image tag)') {
            steps {
                bumpImageTag(
                    service:  env.SERVICE_NAME,
                    env:      env.DEPLOY_ENV,
                    imageTag: env.IMAGE_TAG
                )
            }
        }

        // 9 — Verificación post-sync contra /actuator/health/readiness. Solo en
        //     ambientes con auto-sync (dev/staging); en prod el sync es manual en
        //     ArgoCD, así que el pipeline no espera el despliegue aquí.
        stage('Smoke Tests') {
            when { expression { env.DEPLOY_ENV != 'prod' } }
            steps {
                runSmokeTests(
                    service:   env.SERVICE_NAME,
                    namespace: env.K8S_NAMESPACE,
                    imageTag:  env.IMAGE_TAG
                )
            }
        }
    }

    // 11 — Notificación de resultado (Slack/email).
    post {
        success { notify(status: 'SUCCESS', service: env.SERVICE_NAME, env: env.DEPLOY_ENV) }
        failure { notify(status: 'FAILURE', service: env.SERVICE_NAME, env: env.DEPLOY_ENV) }
    }
}
"""
    return (template
            .replace("__SERVICE_NAME__", project_name)
            .replace("__DB_TYPE__", db_type)
            .replace("__LIB_ORG__", lib_org))


def get_logback_content() -> str:
    return """\
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
    <!-- Fuera de dev: JSON estructurado con traceId/spanId (Micrometer-OTEL los inyecta en el MDC). -->
    <springProfile name="!dev">
        <appender name="JSON" class="ch.qos.logback.core.ConsoleAppender">
            <encoder class="net.logstash.logback.encoder.LogstashEncoder">
                <includeMdcKeyName>traceId</includeMdcKeyName>
                <includeMdcKeyName>spanId</includeMdcKeyName>
            </encoder>
        </appender>
        <root level="INFO">
            <appender-ref ref="JSON"/>
        </root>
    </springProfile>
    <!-- Dev: salida legible por consola, también incluye traceId/spanId. -->
    <springProfile name="dev">
        <appender name="CONSOLE" class="ch.qos.logback.core.ConsoleAppender">
            <encoder>
                <pattern>%d{HH:mm:ss} %-5level [%X{traceId},%X{spanId}] %logger{36} - %msg%n</pattern>
            </encoder>
        </appender>
        <root level="INFO">
            <appender-ref ref="CONSOLE"/>
        </root>
    </springProfile>
</configuration>
"""


def get_dockerignore_content() -> str:
    return """\
target/
.git/
.idea/
*.iml
.env
**/*.class
**/*.log
"""


def get_helm_chart_files(project_name: str, port: int = 8080) -> dict:
    """Helm chart consumido por deployToEks() de la Shared Library.

    Layout esperado por el step: helm/<service>/ con Chart.yaml, values.yaml y
    un values-<env>.yaml por ambiente. El deploy hace
    `--set image.repository=<registry>/<service> --set image.tag=<tag>`.
    """
    chart_yaml = f"""\
apiVersion: v2
name: {project_name}
description: Chart del microservicio {project_name} (Spring Boot WebFlux)
type: application
version: 0.1.0
appVersion: "0.1.0"
"""

    values_yaml = f"""\
# Valores base. En GitOps, image.repository/tag se fijan por ambiente en
# values-<env>.yaml (los escribe el paso bumpImageTag de Jenkins y los lee ArgoCD).
replicaCount: 1

image:
  repository: ""   # <registry>/<service> — definido en values-<env>.yaml
  tag: ""          # <version>-<sha> inmutable — definido en values-<env>.yaml
  pullPolicy: IfNotPresent

service:
  type: ClusterIP
  port: {port}

resources:
  requests:
    cpu: 250m
    memory: 512Mi
  limits:
    cpu: "1"
    memory: 1Gi

# Sondas contra los endpoints de Spring Boot Actuator.
probes:
  readinessPath: /actuator/health/readiness
  livenessPath: /actuator/health/liveness

# Observabilidad: endpoint del OTEL Collector. Se sobreescribe por ambiente en values-<env>.yaml.
otel:
  collectorEndpoint: ""

env: []
"""

    # Overrides por ambiente. prod escala a >=2 réplicas (alta disponibilidad).
    # El bloque image es la fuente de verdad de GitOps: bumpImageTag (Jenkins)
    # reescribe repository/tag y ArgoCD sincroniza el cluster con estos valores.
    image_block = """\
# image.repository / image.tag los fija el pipeline (bumpImageTag); ArgoCD los lee.
image:
  repository: ""
  tag: ""
"""
    values_dev = image_block + f"""\
replicaCount: 1
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 512Mi
otel:
  collectorEndpoint: "http://{project_name}-otel-collector.monitoring:4317"
"""
    values_staging = image_block + """\
replicaCount: 2
otel:
  collectorEndpoint: "http://otel-collector.monitoring:4317"
"""
    values_prod = image_block + """\
replicaCount: 3
resources:
  requests:
    cpu: 500m
    memory: 1Gi
  limits:
    cpu: "2"
    memory: 2Gi
otel:
  collectorEndpoint: "http://otel-collector.monitoring:4317"
"""

    deployment_tpl = """\
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Chart.Name }}
  labels:
    app: {{ .Chart.Name }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Chart.Name }}
  template:
    metadata:
      labels:
        app: {{ .Chart.Name }}
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/path: "/actuator/prometheus"
        prometheus.io/port: "{{ .Values.service.port }}"
    spec:
      initContainers:
        - name: otel-agent
          image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:latest
          command: ["cp", "/javaagent.jar", "/otel/opentelemetry-javaagent.jar"]
          volumeMounts:
            - name: otel-agent
              mountPath: /otel
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - containerPort: {{ .Values.service.port }}
          readinessProbe:
            httpGet:
              path: {{ .Values.probes.readinessPath }}
              port: {{ .Values.service.port }}
            initialDelaySeconds: 15
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: {{ .Values.probes.livenessPath }}
              port: {{ .Values.service.port }}
            initialDelaySeconds: 30
            periodSeconds: 15
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          env:
            - name: OTEL_SERVICE_NAME
              value: "{{ .Chart.Name }}"
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "{{ .Values.otel.collectorEndpoint }}"
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: "deployment.environment={{ .Values.env | default \"dev\" }},service.version={{ .Values.image.tag }}"
            - name: JAVA_TOOL_OPTIONS
              value: "-javaagent:/otel/opentelemetry-javaagent.jar"
            {{- with .Values.env }}
            {{- toYaml . | nindent 12 }}
            {{- end }}
          volumeMounts:
            - name: otel-agent
              mountPath: /otel
      volumes:
        - name: otel-agent
          emptyDir: {}
"""

    service_tpl = """\
apiVersion: v1
kind: Service
metadata:
  name: {{ .Chart.Name }}
  labels:
    app: {{ .Chart.Name }}
spec:
  type: {{ .Values.service.type }}
  selector:
    app: {{ .Chart.Name }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: {{ .Values.service.port }}
      protocol: TCP
"""

    helmignore = """\
.git
*.tmp
*.bak
"""

    return {
        "Chart.yaml": chart_yaml,
        "values.yaml": values_yaml,
        "values-dev.yaml": values_dev,
        "values-staging.yaml": values_staging,
        "values-prod.yaml": values_prod,
        ".helmignore": helmignore,
        "templates/deployment.yaml": deployment_tpl,
        "templates/service.yaml": service_tpl,
    }


def get_root_pom(project_name: str, database: str, messaging_system: str, outbox: bool = False) -> str:
    safe_name = project_name.replace("-", "")
    db_module = "mongo" if database.lower() == "mongo" else "postgres"

    modules = [
        "domain/model",
        "application/use-cases",
        f"infrastructure/driven-adapters/{db_module}",
        "infrastructure/entry-points/rest-api",
        "infrastructure/entry-points/app",
    ]
    if messaging_system.lower() == "rabbit-producer":
        modules.append("infrastructure/driven-adapters/rabbit-producer")
    elif messaging_system.lower() == "rabbit-consumer":
        modules.append("infrastructure/entry-points/rabbit-consumer")
    elif messaging_system.lower() == "kafka-producer":
        modules.append("infrastructure/driven-adapters/kafka-producer")
    elif messaging_system.lower() == "kafka-consumer":
        modules.append("infrastructure/entry-points/kafka-consumer")

    if outbox:
        modules.append("infrastructure/driven-adapters/outbox")

    modules_xml = "\n".join(f"                <module>{m}</module>" for m in modules)

    return f"""\
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>
    <groupId>com.{safe_name}</groupId>
    <artifactId>{project_name}</artifactId>
    <version>0.0.1-SNAPSHOT</version>
    <packaging>pom</packaging>
    <parent>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-parent</artifactId>
        <version>3.4.1</version>
    </parent>
    <properties>
        <java.version>21</java.version>
    </properties>
    <modules>
{modules_xml}
    </modules>
    <dependencyManagement>
        <dependencies>
            <dependency>
                <groupId>io.awspring.cloud</groupId>
                <artifactId>spring-cloud-aws-dependencies</artifactId>
                <version>3.2.1</version>
                <type>pom</type>
                <scope>import</scope>
            </dependency>
        </dependencies>
    </dependencyManagement>
    <dependencies>
        <dependency>
            <groupId>io.awspring.cloud</groupId>
            <artifactId>spring-cloud-aws-starter-secrets-manager</artifactId>
        </dependency>
        <dependency>
            <groupId>io.projectreactor</groupId>
            <artifactId>reactor-core</artifactId>
        </dependency>
        <dependency>
            <groupId>org.projectlombok</groupId>
            <artifactId>lombok</artifactId>
            <optional>true</optional>
        </dependency>
        <dependency>
            <groupId>io.projectreactor</groupId>
            <artifactId>reactor-test</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-actuator</artifactId>
        </dependency>
        <dependency>
            <groupId>io.micrometer</groupId>
            <artifactId>micrometer-registry-prometheus</artifactId>
        </dependency>
        <dependency>
            <groupId>io.micrometer</groupId>
            <artifactId>micrometer-tracing-bridge-otel</artifactId>
        </dependency>
        <dependency>
            <groupId>io.opentelemetry</groupId>
            <artifactId>opentelemetry-exporter-otlp</artifactId>
        </dependency>
        <dependency>
            <groupId>net.logstash.logback</groupId>
            <artifactId>logstash-logback-encoder</artifactId>
            <version>7.4</version>
        </dependency>
    </dependencies>
    <build>
        <pluginManagement>
            <plugins>
                <plugin>
                    <groupId>org.springframework.boot</groupId>
                    <artifactId>spring-boot-maven-plugin</artifactId>
                </plugin>
            </plugins>
        </pluginManagement>
    </build>
</project>
"""


def get_module_pom(parent_artifact_id: str, safe_project_name: str, module_path: str,
                   include_outbox_dep: bool = False) -> str:
    module_artifact_id = module_path.replace("/", "-")
    module_package_name = module_path.split("/")[-1].replace("-", "")
    is_db_adapter = module_path.startswith("infrastructure/driven-adapters/")
    is_entry_points = module_path.startswith("infrastructure/entry-points/")
    is_infrastructure = is_db_adapter or is_entry_points
    relative_path = "../../../pom.xml" if is_infrastructure else "../../pom.xml"

    header = f"""\
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
    <modelVersion>4.0.0</modelVersion>
    <parent>
        <groupId>com.{safe_project_name}</groupId>
        <artifactId>{parent_artifact_id}</artifactId>
        <version>0.0.1-SNAPSHOT</version>
        <relativePath>{relative_path}</relativePath>
    </parent>
    <groupId>com.{safe_project_name}.{module_package_name}</groupId>
    <artifactId>{module_artifact_id}</artifactId>
    <dependencies>
"""

    deps = ""
    if is_db_adapter:
        if module_path.endswith("/mongo"):
            deps = """\
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-data-mongodb-reactive</artifactId>
</dependency>
"""
        elif module_path.endswith("/rabbit-producer"):
            deps = """\
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-amqp</artifactId>
</dependency>
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-webflux</artifactId>
</dependency>
"""
        elif module_path.endswith("/kafka-producer"):
            deps = """\
<dependency>
    <groupId>org.springframework.kafka</groupId>
    <artifactId>spring-kafka</artifactId>
</dependency>
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-webflux</artifactId>
</dependency>
"""
        elif module_path.endswith("/outbox"):
            deps = f"""\
<dependency>
    <groupId>com.{safe_project_name}.model</groupId>
    <artifactId>domain-model</artifactId>
    <version>${{project.version}}</version>
</dependency>
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-data-r2dbc</artifactId>
</dependency>
<dependency>
    <groupId>org.postgresql</groupId>
    <artifactId>r2dbc-postgresql</artifactId>
    <scope>runtime</scope>
</dependency>
<dependency>
    <groupId>org.springframework.kafka</groupId>
    <artifactId>spring-kafka</artifactId>
</dependency>
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-webflux</artifactId>
</dependency>
"""
        else:
            deps = """\
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-data-r2dbc</artifactId>
</dependency>
<dependency>
    <groupId>org.postgresql</groupId>
    <artifactId>r2dbc-postgresql</artifactId>
    <scope>runtime</scope>
</dependency>
"""
    elif module_path == "infrastructure/entry-points/rest-api":
        deps = """\
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-webflux</artifactId>
</dependency>
"""
    elif module_path == "infrastructure/entry-points/app":
        deps = f"""\
<dependency>
    <groupId>com.{safe_project_name}.restapi</groupId>
    <artifactId>infrastructure-entry-points-rest-api</artifactId>
    <version>${{project.version}}</version>
</dependency>
"""
        if include_outbox_dep:
            deps += f"""\
<dependency>
    <groupId>com.{safe_project_name}.outbox</groupId>
    <artifactId>infrastructure-driven-adapters-outbox</artifactId>
    <version>${{project.version}}</version>
</dependency>
"""
    elif module_path == "infrastructure/entry-points/rabbit-consumer":
        deps = """\
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-amqp</artifactId>
</dependency>
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-webflux</artifactId>
</dependency>
"""
    elif module_path == "infrastructure/entry-points/kafka-consumer":
        deps = """\
<dependency>
    <groupId>org.springframework.kafka</groupId>
    <artifactId>spring-kafka</artifactId>
</dependency>
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-webflux</artifactId>
</dependency>
"""

    footer = "</dependencies>\n"

    build_section = ""
    if module_path == "infrastructure/entry-points/app":
        build_section = """\
    <build>
        <plugins>
            <plugin>
                <groupId>org.springframework.boot</groupId>
                <artifactId>spring-boot-maven-plugin</artifactId>
                <configuration>
                    <workingDirectory>${project.basedir}/../../../</workingDirectory>
                </configuration>
            </plugin>
        </plugins>
    </build>
"""

    return header + deps + footer + build_section + "</project>\n"


def create_rabbit_producer_files(root: Path, safe_project_name: str) -> None:
    module_path = "infrastructure/driven-adapters/rabbit-producer"
    module_name = "rabbitproducer"
    base_package = f"com.{safe_project_name}.{module_name}"
    package_path = "/src/main/java/" + base_package.replace(".", "/")

    logger.debug("Generando archivos RabbitMQ producer en: %s", module_path)

    config_class = f"""\
package {base_package};

import org.springframework.amqp.core.Queue;
import org.springframework.amqp.rabbit.connection.ConnectionFactory;
import org.springframework.amqp.rabbit.core.RabbitTemplate;
import org.springframework.amqp.support.converter.Jackson2JsonMessageConverter;
import org.springframework.amqp.support.converter.MessageConverter;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class RabbitMQConfig {{
    public static final String QUEUE_NAME = "messages";

    @Bean
    public Queue messageQueue() {{
        return new Queue(QUEUE_NAME, true);
    }}

    @Bean
    public MessageConverter jsonMessageConverter() {{
        return new Jackson2JsonMessageConverter();
    }}

    @Bean
    public RabbitTemplate rabbitTemplate(ConnectionFactory connectionFactory) {{
        RabbitTemplate template = new RabbitTemplate(connectionFactory);
        template.setMessageConverter(jsonMessageConverter());
        return template;
    }}
}}
"""

    publisher = f"""\
package {base_package};

import reactor.core.publisher.Mono;
import org.springframework.amqp.rabbit.core.RabbitTemplate;
import org.springframework.stereotype.Component;

@Component
public class MessagePublisher {{

    private final RabbitTemplate rabbitTemplate;

    public MessagePublisher(RabbitTemplate rabbitTemplate) {{
        this.rabbitTemplate = rabbitTemplate;
    }}

    public Mono<Void> publish(Object message) {{
        return Mono.fromRunnable(() ->
            rabbitTemplate.convertAndSend(RabbitMQConfig.QUEUE_NAME, message)
        );
    }}
}}
"""

    pkg_dir = root / (module_path + package_path)
    pkg_dir.mkdir(parents=True, exist_ok=True)
    (pkg_dir / "RabbitMQConfig.java").write_text(config_class)
    logger.debug("Archivo creado: %s/RabbitMQConfig.java", pkg_dir)
    (pkg_dir / "MessagePublisher.java").write_text(publisher)
    logger.debug("Archivo creado: %s/MessagePublisher.java", pkg_dir)
    logger.info("Módulo rabbit-producer generado")


def create_rabbit_consumer_files(root: Path, safe_project_name: str) -> None:
    module_path = "infrastructure/entry-points/rabbit-consumer"
    module_name = "rabbitconsumer"
    base_package = f"com.{safe_project_name}.{module_name}"
    package_path = "/src/main/java/" + base_package.replace(".", "/")

    logger.debug("Generando archivos RabbitMQ consumer en: %s", module_path)

    config_class = f"""\
package {base_package};

import org.springframework.amqp.core.Queue;
import org.springframework.amqp.rabbit.connection.ConnectionFactory;
import org.springframework.amqp.rabbit.core.RabbitTemplate;
import org.springframework.amqp.support.converter.Jackson2JsonMessageConverter;
import org.springframework.amqp.support.converter.MessageConverter;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class RabbitMQConfig {{
    public static final String QUEUE_NAME = "messages";

    @Bean
    public Queue messageQueue() {{
        return new Queue(QUEUE_NAME, true);
    }}

    @Bean
    public MessageConverter jsonMessageConverter() {{
        return new Jackson2JsonMessageConverter();
    }}

    @Bean
    public RabbitTemplate rabbitTemplate(ConnectionFactory connectionFactory) {{
        RabbitTemplate template = new RabbitTemplate(connectionFactory);
        template.setMessageConverter(jsonMessageConverter());
        return template;
    }}
}}
"""

    listener = f"""\
package {base_package};

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.amqp.rabbit.annotation.RabbitListener;
import org.springframework.stereotype.Component;

@Component
public class MessageListener {{

    private static final Logger log = LoggerFactory.getLogger(MessageListener.class);

    @RabbitListener(queues = RabbitMQConfig.QUEUE_NAME)
    public void handleMessage(Object message) {{
        log.info("Mensaje recibido: {{}}", message);
    }}
}}
"""

    pkg_dir = root / (module_path + package_path)
    pkg_dir.mkdir(parents=True, exist_ok=True)
    (pkg_dir / "RabbitMQConfig.java").write_text(config_class)
    logger.debug("Archivo creado: %s/RabbitMQConfig.java", pkg_dir)
    (pkg_dir / "MessageListener.java").write_text(listener)
    logger.debug("Archivo creado: %s/MessageListener.java", pkg_dir)
    logger.info("Módulo rabbit-consumer generado")


def create_kafka_producer_files(root: Path, safe_project_name: str) -> None:
    module_path = "infrastructure/driven-adapters/kafka-producer"
    module_name = "kafkaproducer"
    base_package = f"com.{safe_project_name}.{module_name}"
    package_path = "/src/main/java/" + base_package.replace(".", "/")

    logger.debug("Generando archivos Kafka producer en: %s", module_path)

    config_class = f"""\
package {base_package};

import org.apache.kafka.clients.producer.ProducerConfig;
import org.apache.kafka.common.serialization.StringSerializer;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.kafka.core.DefaultKafkaProducerFactory;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.core.ProducerFactory;
import org.springframework.kafka.support.serializer.JsonSerializer;

import java.util.HashMap;
import java.util.Map;

@Configuration
public class KafkaProducerConfig {{

    @Value("${{spring.kafka.bootstrap-servers}}")
    private String bootstrapServers;

    @Bean
    public ProducerFactory<String, Object> producerFactory() {{
        Map<String, Object> props = new HashMap<>();
        props.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        props.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class);
        props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, JsonSerializer.class);
        return new DefaultKafkaProducerFactory<>(props);
    }}

    @Bean
    public KafkaTemplate<String, Object> kafkaTemplate() {{
        return new KafkaTemplate<>(producerFactory());
    }}
}}
"""

    publisher = f"""\
package {base_package};

import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.stereotype.Component;
import reactor.core.publisher.Mono;
import reactor.core.scheduler.Schedulers;

@Component
public class MessageProducer {{

    public static final String TOPIC = "messages";

    private final KafkaTemplate<String, Object> kafkaTemplate;

    public MessageProducer(KafkaTemplate<String, Object> kafkaTemplate) {{
        this.kafkaTemplate = kafkaTemplate;
    }}

    public Mono<Void> send(Object message) {{
        return Mono.fromFuture(() -> kafkaTemplate.send(TOPIC, message).toCompletableFuture())
                .subscribeOn(Schedulers.boundedElastic())
                .then();
    }}
}}
"""

    pkg_dir = root / (module_path + package_path)
    pkg_dir.mkdir(parents=True, exist_ok=True)
    (pkg_dir / "KafkaProducerConfig.java").write_text(config_class)
    logger.debug("Archivo creado: %s/KafkaProducerConfig.java", pkg_dir)
    (pkg_dir / "MessageProducer.java").write_text(publisher)
    logger.debug("Archivo creado: %s/MessageProducer.java", pkg_dir)
    logger.info("Módulo kafka-producer generado")


def create_kafka_consumer_files(root: Path, safe_project_name: str) -> None:
    module_path = "infrastructure/entry-points/kafka-consumer"
    module_name = "kafkaconsumer"
    base_package = f"com.{safe_project_name}.{module_name}"
    package_path = "/src/main/java/" + base_package.replace(".", "/")

    logger.debug("Generando archivos Kafka consumer en: %s", module_path)

    config_class = f"""\
package {base_package};

import org.apache.kafka.clients.consumer.ConsumerConfig;
import org.apache.kafka.common.serialization.StringDeserializer;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.kafka.annotation.EnableKafka;
import org.springframework.kafka.config.ConcurrentKafkaListenerContainerFactory;
import org.springframework.kafka.core.ConsumerFactory;
import org.springframework.kafka.core.DefaultKafkaConsumerFactory;
import org.springframework.kafka.support.serializer.JsonDeserializer;

import java.util.HashMap;
import java.util.Map;

@EnableKafka
@Configuration
public class KafkaConsumerConfig {{

    @Value("${{spring.kafka.bootstrap-servers}}")
    private String bootstrapServers;

    @Value("${{spring.kafka.consumer.group-id}}")
    private String groupId;

    @Bean
    public ConsumerFactory<String, Object> consumerFactory() {{
        Map<String, Object> props = new HashMap<>();
        props.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        props.put(ConsumerConfig.GROUP_ID_CONFIG, groupId);
        props.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");
        props.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class);
        props.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, JsonDeserializer.class);
        props.put(JsonDeserializer.TRUSTED_PACKAGES, "*");
        return new DefaultKafkaConsumerFactory<>(props);
    }}

    @Bean
    public ConcurrentKafkaListenerContainerFactory<String, Object> kafkaListenerContainerFactory() {{
        ConcurrentKafkaListenerContainerFactory<String, Object> factory =
                new ConcurrentKafkaListenerContainerFactory<>();
        factory.setConsumerFactory(consumerFactory());
        return factory;
    }}
}}
"""

    listener = f"""\
package {base_package};

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.stereotype.Component;

@Component
public class MessageConsumer {{

    private static final Logger log = LoggerFactory.getLogger(MessageConsumer.class);

    @KafkaListener(topics = "messages", groupId = "${{spring.kafka.consumer.group-id}}")
    public void handleMessage(Object message) {{
        log.info("Mensaje recibido: {{}}", message);
    }}
}}
"""

    pkg_dir = root / (module_path + package_path)
    pkg_dir.mkdir(parents=True, exist_ok=True)
    (pkg_dir / "KafkaConsumerConfig.java").write_text(config_class)
    logger.debug("Archivo creado: %s/KafkaConsumerConfig.java", pkg_dir)
    (pkg_dir / "MessageConsumer.java").write_text(listener)
    logger.debug("Archivo creado: %s/MessageConsumer.java", pkg_dir)
    logger.info("Módulo kafka-consumer generado")


def create_outbox_files(root: Path, safe_project_name: str) -> None:
    """Módulo Transactional Outbox: publicación de eventos atómica con el cambio de BD."""
    module_path = "infrastructure/driven-adapters/outbox"
    base_package = f"com.{safe_project_name}.outbox"
    pkg_dir = root / (module_path + "/src/main/java/" + base_package.replace(".", "/"))
    pkg_dir.mkdir(parents=True, exist_ok=True)
    model_pkg = f"com.{safe_project_name}.model"

    # Puerto en el dominio (el adaptador lo implementa)
    model_dir = root / ("domain/model/src/main/java/" + model_pkg.replace(".", "/"))
    model_dir.mkdir(parents=True, exist_ok=True)
    (model_dir / "OutboxPort.java").write_text(f"""\
package {model_pkg};

import reactor.core.publisher.Mono;

/** Puerto secundario de publicación confiable de eventos (Transactional Outbox). */
public interface OutboxPort {{
    Mono<Void> append(String aggregateType, String aggregateId, String eventType, String topic, String payload);
}}
""")

    (pkg_dir / "OutboxMessage.java").write_text(f"""\
package {base_package};

import org.springframework.data.annotation.Id;
import org.springframework.data.relational.core.mapping.Column;
import org.springframework.data.relational.core.mapping.Table;

import java.time.Instant;

@Table("outbox")
public class OutboxMessage {{
    @Id
    private Long id;
    @Column("aggregate_type") private String aggregateType;
    @Column("aggregate_id") private String aggregateId;
    @Column("event_type") private String eventType;
    private String topic;
    private String payload;
    private String status;
    @Column("created_at") private Instant createdAt;
    @Column("published_at") private Instant publishedAt;

    public Long getId() {{ return id; }}
    public void setId(Long id) {{ this.id = id; }}
    public String getAggregateType() {{ return aggregateType; }}
    public void setAggregateType(String v) {{ this.aggregateType = v; }}
    public String getAggregateId() {{ return aggregateId; }}
    public void setAggregateId(String v) {{ this.aggregateId = v; }}
    public String getEventType() {{ return eventType; }}
    public void setEventType(String v) {{ this.eventType = v; }}
    public String getTopic() {{ return topic; }}
    public void setTopic(String v) {{ this.topic = v; }}
    public String getPayload() {{ return payload; }}
    public void setPayload(String v) {{ this.payload = v; }}
    public String getStatus() {{ return status; }}
    public void setStatus(String v) {{ this.status = v; }}
    public Instant getCreatedAt() {{ return createdAt; }}
    public void setCreatedAt(Instant v) {{ this.createdAt = v; }}
    public Instant getPublishedAt() {{ return publishedAt; }}
    public void setPublishedAt(Instant v) {{ this.publishedAt = v; }}
}}
""")

    (pkg_dir / "OutboxRepository.java").write_text(f"""\
package {base_package};

import org.springframework.data.repository.reactive.ReactiveCrudRepository;
import reactor.core.publisher.Flux;

public interface OutboxRepository extends ReactiveCrudRepository<OutboxMessage, Long> {{
    Flux<OutboxMessage> findTop100ByStatusOrderByCreatedAtAsc(String status);
}}
""")

    (pkg_dir / "OutboxAdapter.java").write_text(f"""\
package {base_package};

import {model_pkg}.OutboxPort;
import org.springframework.stereotype.Component;
import reactor.core.publisher.Mono;

import java.time.Instant;

/** Implementa OutboxPort: escribe el evento en la tabla outbox (misma transacción que el cambio de BD). */
@Component
public class OutboxAdapter implements OutboxPort {{

    private final OutboxRepository repository;

    public OutboxAdapter(OutboxRepository repository) {{
        this.repository = repository;
    }}

    @Override
    public Mono<Void> append(String aggregateType, String aggregateId, String eventType, String topic, String payload) {{
        OutboxMessage message = new OutboxMessage();
        message.setAggregateType(aggregateType);
        message.setAggregateId(aggregateId);
        message.setEventType(eventType);
        message.setTopic(topic);
        message.setPayload(payload);
        message.setStatus("PENDING");
        message.setCreatedAt(Instant.now());
        return repository.save(message).then();
    }}
}}
""")

    (pkg_dir / "OutboxKafkaConfig.java").write_text(f"""\
package {base_package};

import org.apache.kafka.clients.producer.ProducerConfig;
import org.apache.kafka.common.serialization.StringSerializer;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.kafka.core.DefaultKafkaProducerFactory;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.core.ProducerFactory;
import org.springframework.scheduling.annotation.EnableScheduling;

import java.util.HashMap;
import java.util.Map;

@Configuration
@EnableScheduling
public class OutboxKafkaConfig {{

    @Value("${{spring.kafka.bootstrap-servers:localhost:9092}}")
    private String bootstrapServers;

    @Bean
    public ProducerFactory<String, String> outboxProducerFactory() {{
        Map<String, Object> props = new HashMap<>();
        props.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        props.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class);
        props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class);
        return new DefaultKafkaProducerFactory<>(props);
    }}

    @Bean
    public KafkaTemplate<String, String> outboxKafkaTemplate() {{
        return new KafkaTemplate<>(outboxProducerFactory());
    }}
}}
""")

    (pkg_dir / "OutboxRelay.java").write_text(f"""\
package {base_package};

import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import reactor.core.publisher.Mono;

import java.time.Instant;

/** Relay del outbox: publica periódicamente los eventos PENDING a Kafka y los marca PUBLISHED. */
@Component
public class OutboxRelay {{

    private final OutboxRepository repository;
    private final KafkaTemplate<String, String> outboxKafkaTemplate;

    public OutboxRelay(OutboxRepository repository, KafkaTemplate<String, String> outboxKafkaTemplate) {{
        this.repository = repository;
        this.outboxKafkaTemplate = outboxKafkaTemplate;
    }}

    @Scheduled(fixedDelayString = "${{outbox.relay.fixed-delay:5000}}")
    public void publishPending() {{
        repository.findTop100ByStatusOrderByCreatedAtAsc("PENDING")
                .flatMap(message -> Mono.fromFuture(
                                outboxKafkaTemplate.send(message.getTopic(), message.getAggregateId(), message.getPayload())
                                        .toCompletableFuture())
                        .flatMap(result -> {{
                            message.setStatus("PUBLISHED");
                            message.setPublishedAt(Instant.now());
                            return repository.save(message);
                        }}))
                .subscribe();
    }}
}}
""")
    logger.info("Módulo outbox generado")


def create_compensation_controller(root: Path, safe_project_name: str) -> None:
    """Endpoint de compensación idempotente para servicios participantes de una saga."""
    base_package = f"com.{safe_project_name}.restapi"
    pkg_dir = root / ("infrastructure/entry-points/rest-api/src/main/java/" + base_package.replace(".", "/"))
    pkg_dir.mkdir(parents=True, exist_ok=True)
    (pkg_dir / "CompensationController.java").write_text(f"""\
package {base_package};

import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import reactor.core.publisher.Mono;

/**
 * Endpoint de compensación idempotente que el orquestador de saga (integration-service) invoca
 * para revertir un paso. La lógica se implementa bajo TDD; la idempotencia se respalda en la
 * tabla processed_message.
 */
@RestController
@RequestMapping("/saga")
public class CompensationController {{

    @PostMapping("/compensar/{{sagaId}}")
    public Mono<ResponseEntity<Void>> compensar(@PathVariable String sagaId) {{
        // TODO (TDD): invocar el caso de uso de compensación; idempotente vía processed_message.
        return Mono.just(ResponseEntity.accepted().build());
    }}
}}
""")
    logger.info("CompensationController generado (servicio participante de saga)")


def write_liquibase_structure(root: Path, project_name: str, pg_db_prefix: str,
                               outbox: bool, saga_participant: bool,
                               migrations_dir: str = "") -> None:
    """Genera <migrations_dir>/<project_name>/changelog/ (Liquibase standalone).

    Flyway requiere JDBC bloqueante — incompatible con servicios R2DBC. Liquibase corre
    como proceso independiente antes del despliegue; no va en el classpath del JAR.
    Si migrations_dir está vacío usa REPO_ROOT/db/ (root.parent.parent / "db").
    """
    if migrations_dir:
        db_svc_dir = Path(migrations_dir) / project_name
    else:
        db_svc_dir = root.parent.parent / "db" / project_name
    changelog_dir = db_svc_dir / "changelog"
    changelog_dir.mkdir(parents=True, exist_ok=True)

    svc_slug = project_name.replace("-", "_")
    db_name = f"{pg_db_prefix}_{svc_slug}" if pg_db_prefix else svc_slug

    (db_svc_dir / "liquibase.properties").write_text(
        f"url=jdbc:postgresql://${{VPS_IP:-localhost}}:5432/{db_name}\n"
        f"username=${{DB_USERNAME}}\n"
        f"password=${{DB_PASSWORD}}\n"
        "changeLogFile=changelog/root.yaml\n"
        "liquibaseSchemaName=public\n"
    )

    includes = (
        "  - include:\n"
        "      file: changelog/00001_initial_schema.yaml\n"
        "      relativeToChangelogFile: true\n"
    )
    if outbox or saga_participant:
        includes += (
            "  - include:\n"
            "      file: changelog/00003_outbox.yaml\n"
            "      relativeToChangelogFile: true\n"
        )
    (changelog_dir / "root.yaml").write_text("databaseChangeLog:\n" + includes)

    (changelog_dir / "00001_initial_schema.yaml").write_text(
        "databaseChangeLog:\n"
        "  - changeSet:\n"
        "      id: 00001-initial-schema\n"
        "      author: scaffold\n"
        f"      comment: \"Schema inicial de {project_name} — generado por scaffold-all-services.sh\"\n"
        "      changes:\n"
        "        - sql:\n"
        "            sql: |\n"
        "              -- TODO: contenido poblado por scaffold-all-services.sh --bc-tags\n"
        "            stripComments: true\n"
    )

    if outbox or saga_participant:
        parts = ["databaseChangeLog:"]
        if outbox:
            parts += [
                "  - changeSet:",
                "      id: 00003-outbox",
                "      author: scaffold",
                "      comment: \"Transactional Outbox — publicación atómica con cambio de BD\"",
                "      changes:",
                "        - sql:",
                "            sql: |",
                "              CREATE TABLE IF NOT EXISTS outbox (",
                "                  id             BIGSERIAL    PRIMARY KEY,",
                "                  aggregate_type VARCHAR(120) NOT NULL,",
                "                  aggregate_id   VARCHAR(120) NOT NULL,",
                "                  event_type     VARCHAR(120) NOT NULL,",
                "                  topic          VARCHAR(200) NOT NULL,",
                "                  payload        TEXT         NOT NULL,",
                "                  status         VARCHAR(20)  NOT NULL DEFAULT 'PENDING',",
                "                  created_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),",
                "                  published_at   TIMESTAMPTZ",
                "              );",
                "              CREATE INDEX IF NOT EXISTS idx_outbox_status_created ON outbox (status, created_at);",
                "            stripComments: true",
            ]
        if outbox or saga_participant:
            parts += [
                "  - changeSet:",
                "      id: 00003-processed-message",
                "      author: scaffold",
                "      comment: \"Idempotencia de consumidores y compensaciones de saga\"",
                "      changes:",
                "        - sql:",
                "            sql: |",
                "              CREATE TABLE IF NOT EXISTS processed_message (",
                "                  message_id   VARCHAR(120) PRIMARY KEY,",
                "                  consumer     VARCHAR(120) NOT NULL,",
                "                  processed_at TIMESTAMPTZ  NOT NULL DEFAULT now()",
                "              );",
                "            stripComments: true",
            ]
        (changelog_dir / "00003_outbox.yaml").write_text("\n".join(parts) + "\n")
        logger.info("Liquibase 00003_outbox.yaml generado en: %s", changelog_dir)

    logger.info("Liquibase structure generada en: %s", db_svc_dir)


def scaffold(project_name: str, database: str, messaging_system: str, port: int = 8080,
             org: str = "myproject", outbox: bool = False, saga_participant: bool = False,
             pg_db_prefix: str = "", mongo_db_prefix: str = "",
             migrations_dir: str = "") -> None:
    safe_name = project_name.replace("-", "")
    root = Path(project_name)
    logger.info("Creando proyecto: %s (db=%s, messaging=%s, port=%d, outbox=%s, saga_participant=%s)",
                project_name, database, messaging_system, port, outbox, saga_participant)

    db_adapter_module = (
        "infrastructure/driven-adapters/mongo"
        if database.lower() == "mongo"
        else "infrastructure/driven-adapters/postgres"
    )

    modules = [
        "domain/model",
        "application/use-cases",
        db_adapter_module,
        "infrastructure/entry-points/rest-api",
        "infrastructure/entry-points/app",
    ]

    if messaging_system.lower() == "rabbit-producer":
        modules.append("infrastructure/driven-adapters/rabbit-producer")
        logger.debug("Mensajería habilitada: rabbit-producer")
    elif messaging_system.lower() == "rabbit-consumer":
        modules.append("infrastructure/entry-points/rabbit-consumer")
        logger.debug("Mensajería habilitada: rabbit-consumer")
    elif messaging_system.lower() == "kafka-producer":
        modules.append("infrastructure/driven-adapters/kafka-producer")
        logger.debug("Mensajería habilitada: kafka-producer")
    elif messaging_system.lower() == "kafka-consumer":
        modules.append("infrastructure/entry-points/kafka-consumer")
        logger.debug("Mensajería habilitada: kafka-consumer")

    if outbox:
        modules.append("infrastructure/driven-adapters/outbox")
        logger.debug("Transactional Outbox habilitado")

    logger.info("Módulos a generar: %d", len(modules))

    for module in modules:
        logger.debug("Procesando módulo: %s", module)
        module_name = module.split("/")[-1].replace("-", "")
        base_package = f"com.{safe_name}.{module_name}"
        package_path = "/src/main/java/" + base_package.replace(".", "/")

        pkg_dir = root / (module + package_path)
        pkg_dir.mkdir(parents=True, exist_ok=True)

        pom_path = root / module / "pom.xml"
        pom_path.write_text(get_module_pom(project_name, safe_name, module, include_outbox_dep=outbox))
        logger.debug("pom.xml creado: %s", pom_path)

        if module == "infrastructure/entry-points/rest-api":
            controller = f"""\
package {base_package};

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import reactor.core.publisher.Mono;

@RestController
public class HelloController {{
    @GetMapping("/hello")
    public Mono<String> sayHello() {{
        return Mono.just("¡Hola desde el scaffold Hexagonal Reactivo!");
    }}
}}
"""
            (pkg_dir / "HelloController.java").write_text(controller)
            logger.debug("HelloController.java creado en: %s", pkg_dir)

        if module == "infrastructure/entry-points/app":
            main_package = f"com.{safe_name}"
            main_class_path = "/src/main/java/" + main_package.replace(".", "/")
            main_dir = root / (module + main_class_path)
            main_dir.mkdir(parents=True, exist_ok=True)

            main_class = f"""\
package {main_package};

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class MainApplication {{
    public static void main(String[] args) {{
        SpringApplication.run(MainApplication.class, args);
    }}
}}
"""
            (main_dir / "MainApplication.java").write_text(main_class)
            logger.debug("MainApplication.java creado en: %s", main_dir)

            app_config = f"""\
package {main_package};

import org.springframework.context.annotation.ComponentScan;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.FilterType;

@Configuration
@ComponentScan(
        basePackages = {{
                "{main_package}.usecases",
                "{main_package}.restapi",
                "{main_package}.app"
        }},
        includeFilters = {{
                @ComponentScan.Filter(
                        type = FilterType.REGEX,
                        pattern = ".*UseCase?$"
                )
        }},
        useDefaultFilters = false
)
public class ApplicationConfig {{
}}
"""
            (main_dir / "ApplicationConfig.java").write_text(app_config)
            logger.debug("ApplicationConfig.java creado en: %s", main_dir)

            resources_dir = root / module / "src/main/resources"
            resources_dir.mkdir(parents=True, exist_ok=True)
            (resources_dir / "application.yml").write_text(get_yaml_content(project_name, database, messaging_system, port, org))
            (resources_dir / "application-dev.yml").write_text(get_dev_yaml_content())
            (resources_dir / "logback-spring.xml").write_text(get_logback_content())
            logger.debug("application.yml y logback-spring.xml creados en: %s", resources_dir)

        logger.info("Módulo listo: %s", module)

    if messaging_system.lower() == "rabbit-producer":
        create_rabbit_producer_files(root, safe_name)
    elif messaging_system.lower() == "rabbit-consumer":
        create_rabbit_consumer_files(root, safe_name)
    elif messaging_system.lower() == "kafka-producer":
        create_kafka_producer_files(root, safe_name)
    elif messaging_system.lower() == "kafka-consumer":
        create_kafka_consumer_files(root, safe_name)

    if outbox:
        create_outbox_files(root, safe_name)
    if saga_participant:
        create_compensation_controller(root, safe_name)
    if database.lower() != "mongo":
        write_liquibase_structure(root, project_name, pg_db_prefix, outbox, saga_participant,
                                  migrations_dir=migrations_dir)

    secrets_dir = root / "scripts"
    secrets_dir.mkdir(parents=True, exist_ok=True)
    secrets_script = secrets_dir / "create-secrets-dev.sh"
    secrets_script.write_text(get_secrets_setup_content(
        project_name, database, messaging_system, port, org,
        pg_db_prefix=pg_db_prefix, mongo_db_prefix=mongo_db_prefix))
    secrets_script.chmod(0o755)
    logger.debug("scripts/create-secrets-dev.sh creado")

    gitignore = """\
target/
!.mvn/wrapper/maven-wrapper.jar
*.class
*.log
*.ctxt
.mtj.tmp/
*.jar
*.war
*.ear
*.zip
*.tar.gz
*.rar
hs_err_pid*
.idea/
*.iml
.classpath
.project
.settings/
bin/
.vscode/
"""
    (root / ".gitignore").write_text(gitignore)
    logger.debug(".gitignore creado")
    (root / "pom.xml").write_text(get_root_pom(project_name, database, messaging_system, outbox=outbox))
    logger.debug("pom.xml raíz creado")

    (root / "Dockerfile").write_text(get_dockerfile_content(database, messaging_system, port, outbox=outbox))
    logger.debug("Dockerfile creado")
    (root / ".dockerignore").write_text(get_dockerignore_content())
    logger.debug(".dockerignore creado")

    (root / "Jenkinsfile").write_text(get_jenkinsfile_content(project_name, database, org))
    logger.debug("Jenkinsfile creado")

    # Helm chart consumido por deployToEks() de la Shared Library.
    helm_root = root / "helm" / project_name
    for rel_path, content in get_helm_chart_files(project_name, port).items():
        target = helm_root / rel_path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
    logger.debug("Helm chart creado en %s", helm_root)

    logger.info("Proyecto creado exitosamente en: %s", root.resolve())
    _update_terraform_services(project_name)
    _update_argocd_applicationset(project_name, org)
    _setup_gitea_repo(project_name, root, org)
    _print_run_instructions(project_name, root, messaging_system, port, org)


def _setup_gitea_repo(project_name: str, root: Path, org: str = "myproject") -> None:
    import base64
    import json as _json
    import subprocess
    import urllib.error
    import urllib.request

    import os
    vps_ip = os.environ.get("VPS_IP", "")
    gitea_host = f"http://{vps_ip}:3000" if vps_ip else "http://localhost:3000"
    credentials = base64.b64encode(b"gitea-admin:gitea-admin").decode()

    try:
        urllib.request.urlopen(f"{gitea_host}/api/healthz", timeout=3)
    except Exception:
        logger.warning(
            "[Gitea] No activo en %s — pasar VPS_IP=<IP> o crear repo manualmente "
            "tras correr base-infrastructure-builder.sh --vps-ip.", gitea_host
        )
        return

    payload = _json.dumps({
        "name": project_name,
        "private": True,
        "auto_init": False,
        "default_branch": "main",
    }).encode()
    req = urllib.request.Request(
        f"{gitea_host}/api/v1/orgs/{org}/repos",
        data=payload,
        headers={"Content-Type": "application/json", "Authorization": f"Basic {credentials}"},
        method="POST",
    )
    try:
        urllib.request.urlopen(req, timeout=5)
        logger.info("[Gitea] Repo %s/%s creado.", org, project_name)
    except urllib.error.HTTPError as e:
        if e.code == 409:
            logger.info("[Gitea] Repo %s/%s ya existe.", org, project_name)
        elif e.code == 401:
            logger.warning(
                "[Gitea] HTTP 401: el usuario admin no existe. Correr "
                "base-infrastructure-builder.sh primero."
            )
            return
        else:
            logger.warning("[Gitea] No se pudo crear el repo: HTTP %s", e.code)
            return

    try:
        subprocess.run(["git", "init", "-q", "-b", "main"], cwd=root, check=True)
        result = subprocess.run(["git", "config", "user.email"], cwd=root, capture_output=True)
        if result.returncode != 0:
            subprocess.run(["git", "config", "user.email", f"cicd@{org}.local"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.name", f"{org} CI"], cwd=root, check=True)
        subprocess.run(["git", "add", "-A"], cwd=root, check=True)
        subprocess.run(["git", "commit", "-q", "-m", f"chore: scaffold {project_name}"], cwd=root, check=True)
        remote_url = f"{gitea_host}/{org}/{project_name}.git"
        subprocess.run(["git", "remote", "add", "origin", remote_url], cwd=root, check=False)
        logger.info("[Gitea] Remote 'origin' → %s", remote_url)
        logger.info("[Gitea] URL para Jenkins/ArgoCD: %s/%s/%s.git", gitea_host, org, project_name)
        # Auto-push con credenciales embebidas (sin guardarlas en .git/config).
        push_url = remote_url.replace("http://", "http://gitea-admin:gitea-admin@", 1)
        push = subprocess.run(
            ["git", "push", push_url, "main"], cwd=root, capture_output=True
        )
        if push.returncode == 0:
            logger.info("[Gitea] Push a %s/%s completado (rama main).", org, project_name)
        else:
            logger.info("[Gitea] Para publicar: cd %s && git push -u origin main", root)
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        logger.warning("[Gitea] No se pudo inicializar el repo git: %s", e)


def _update_argocd_applicationset(service_name: str, org: str = "myproject") -> None:
    repo_root = Path(__file__).parent.parent.parent
    envs = ["dev", "staging", "prod"]
    sentinel = "          # -- services managed by scaffold --\n"
    entry = (
        f"          - service: {service_name}\n"
        f"            repoURL: {gitea_host}/{org}/{service_name}.git\n"
        f"            revision: main\n"
    )

    for env in envs:
        appset = (
            repo_root
            / "terraform" / "backend" / "environments" / env
            / "argocd-bootstrap" / "applicationset.yaml"
        )
        if not appset.exists():
            logger.debug("[ArgoCD] %s no encontrado, omitiendo", appset)
            continue

        content = appset.read_text()
        if f"service: {service_name}" in content:
            logger.debug("[ArgoCD] '%s' ya existe en applicationset.yaml (%s)", service_name, env)
            continue

        if sentinel not in content:
            logger.warning("[ArgoCD] Sentinel no encontrado en %s", appset)
            continue

        appset.write_text(content.replace(sentinel, sentinel + entry))
        logger.info("[ArgoCD] '%s' añadido a applicationset.yaml (%s)", service_name, env)


def _update_terraform_services(service_name: str) -> None:
    repo_root = Path(__file__).parent.parent.parent
    envs = ["dev", "staging", "prod"]
    pattern = re.compile(r'(services\s*=\s*\[)([^\]]*?)(\])')

    for env in envs:
        main_tf = repo_root / "terraform" / "backend" / "environments" / env / "main.tf"
        if not main_tf.exists():
            logger.debug("[Terraform] %s no encontrado, omitiendo", main_tf)
            continue

        content = main_tf.read_text()
        match = pattern.search(content)
        if not match:
            logger.warning("[Terraform] No se encontró 'services' en %s", main_tf)
            continue

        existing = [s.strip().strip('"') for s in match.group(2).split(',') if s.strip().strip('"')]
        if service_name in existing:
            logger.info("[Terraform] '%s' ya existe en services (%s)", service_name, env)
            continue

        existing.append(service_name)
        new_list = ", ".join(f'"{s}"' for s in existing)
        new_content = content[:match.start()] + f'{match.group(1)}{new_list}{match.group(3)}' + content[match.end():]
        main_tf.write_text(new_content)
        logger.info("[Terraform] Agregado '%s' a services en %s", service_name, env)


def _print_run_instructions(project_name: str, root: Path, messaging_system: str, port: int = 8080, org: str = "myproject") -> None:
    rabbit_note = ""
    if messaging_system.lower() in ("rabbit-producer", "rabbit-consumer"):
        rabbit_note = "\n  # Asegúrate de tener RabbitMQ corriendo antes de iniciar:\n  docker run -d --name rabbitmq -p 5672:5672 -p 15672:15672 rabbitmq:3-management\n"
    elif messaging_system.lower() in ("kafka-producer", "kafka-consumer"):
        rabbit_note = "\n  # Asegúrate de tener Kafka corriendo antes de iniciar:\n  docker run -d --name kafka -p 9092:9092 -e KAFKA_CFG_NODE_ID=0 -e KAFKA_CFG_PROCESS_ROLES=controller,broker -e KAFKA_CFG_LISTENERS=PLAINTEXT://:9092,CONTROLLER://:9093 -e KAFKA_CFG_LISTENER_SECURITY_PROTOCOL_MAP=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT -e KAFKA_CFG_CONTROLLER_QUORUM_VOTERS=0@kafka:9093 -e KAFKA_CFG_CONTROLLER_LISTENER_NAMES=CONTROLLER bitnami/kafka:latest\n"

    instructions = f"""
╔══════════════════════════════════════════════════════════════════════╗
║              Proyecto listo: {project_name:<40}║
╚══════════════════════════════════════════════════════════════════════╝

 ── Ejecución local (Maven) ────────────────────────────────────────────

 1. Entra al directorio del proyecto:
    cd {root}

 2. Asegúrate de que floci esté corriendo y crea el secret de desarrollo:
    bash scripts/create-secrets-dev.sh
{rabbit_note}
 3. Compila el proyecto:
    mvn clean install -DskipTests

 4. Ejecuta la aplicación (perfil dev → apunta a floci):
    SPRING_PROFILES_ACTIVE=dev \\
    mvn -pl infrastructure/entry-points/app spring-boot:run

 5. Verifica que está corriendo:
    curl http://localhost:{port}/hello

 ── Ejecución con Docker ───────────────────────────────────────────────

    # Construir la imagen
    docker build -t {project_name}:latest .

    # Ejecutar apuntando a floci del host (o a AWS real en staging/prod)
    docker run -d --name {project_name} \\
      -e SPRING_PROFILES_ACTIVE=dev \\
      -e APP_ENV=dev \\
      --network host \\
      -p {port}:{port} \\
      {project_name}:latest

 Verificar contenedor:
    docker logs -f {project_name}
    curl http://localhost:{port}/hello

 Detener y eliminar:
    docker rm -f {project_name}

 ── AWS Secrets Manager ────────────────────────────────────────────────

 Secret path:  {org}/<APP_ENV>/{project_name}
 Perfil dev:   application-dev.yml apunta a floci (http://localhost:4566)
 Staging/prod: usa IRSA (ServiceAccount 'jenkins-agent' en EKS), sin credenciales
               hardcodeadas. Cambiar APP_ENV=staging|prod al desplegar.

────────────────────────────────────────────────────────────────────────
"""
    print(instructions)


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="maven_hexagonal_scaffold",
        description="Genera un proyecto base Spring Boot Reactivo multimódulo.",
    )
    parser.add_argument("-n", "--service-name", required=True, default="mi-microservicio",
                        metavar="NAME", help="Nombre del microservicio")
    parser.add_argument("-d", "--database", required=True, default="postgres",
                        choices=["postgres", "mongo"], help="Base de datos a configurar")
    parser.add_argument("-m", "--messaging-system", default="none",
                        choices=["none", "rabbit-producer", "rabbit-consumer", "kafka-producer", "kafka-consumer"],
                        help="Sistema de mensajería a configurar")
    parser.add_argument("-p", "--port", type=int, default=8080,
                        metavar="PORT", help="Puerto HTTP del servidor (default: 8080)")
    parser.add_argument("--org", default="myproject", metavar="ORG",
                        help="Slug del proyecto/organización. Se usa para el prefijo de "
                             "secrets (<org>/dev/<servicio>), la organización Gitea y el "
                             "paquete de la Shared Library (org.<org>). Debe coincidir con "
                             "el -P/--project usado en los scripts. (default: myproject)")
    parser.add_argument("--pg-db", default="", metavar="PREFIX",
                        help="Prefijo del nombre de BD PostgreSQL (Database-per-Service). "
                             "BD generada: <prefix>_<servicio_slug>. Debe coincidir con "
                             "el -p/--pg-db de init-databases.sh y create-all-secrets-dev.sh.")
    parser.add_argument("--mongo-db", default="", metavar="PREFIX",
                        help="Prefijo del nombre de BD MongoDB (Database-per-Service). "
                             "BD generada: <prefix>_<servicio_slug>.")
    parser.add_argument("--outbox", action="store_true",
                        help="Añade el módulo Transactional Outbox (publicación de eventos "
                             "atómica con el cambio de BD) y el changelog Liquibase 00003_outbox.yaml.")
    parser.add_argument("--saga-participant", action="store_true",
                        help="Marca el servicio como participante de una saga: genera el "
                             "endpoint de compensación idempotente y la tabla processed_message.")
    parser.add_argument("--migrations-dir", default="", metavar="PATH",
                        help="Ruta absoluta al repositorio de migraciones Liquibase. "
                             "Si se omite, los changelogs se generan en <repo_root>/db/.")
    parser.add_argument("-v", "--verbose", action="store_true",
                        help="Mostrar logs detallados (DEBUG)")

    args = parser.parse_args()

    log_level = logging.DEBUG if args.verbose else logging.INFO
    logging.basicConfig(
        level=log_level,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
        stream=sys.stdout,
    )

    try:
        scaffold(args.service_name, args.database, args.messaging_system, args.port, args.org,
                 outbox=args.outbox, saga_participant=args.saga_participant,
                 pg_db_prefix=args.pg_db, mongo_db_prefix=args.mongo_db,
                 migrations_dir=args.migrations_dir)
    except OSError as e:
        logger.error("No se pudo crear el proyecto: %s", e)
        sys.exit(1)


if __name__ == "__main__":
    main()
