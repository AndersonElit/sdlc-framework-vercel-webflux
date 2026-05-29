#!/usr/bin/env python3
"""Genera un proyecto base Spring Boot Reactivo multimódulo con arquitectura hexagonal."""

import argparse
import logging
import sys
from pathlib import Path

logger = logging.getLogger(__name__)


def get_yaml_content(database: str, messaging_system: str) -> str:
    lines = ["spring:"]
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

    lines += ["server:", "  port: ${SERVER_PORT}"]
    return "\n".join(lines) + "\n"


def get_env_content(project_name: str, database: str, messaging_system: str) -> str:
    lines = [
        f"# {'=' * 67}",
        f"# Environment Variables - {project_name}",
        f"# {'=' * 67}",
        "# IMPORTANT: This file contains sensitive credentials.",
        "# DO NOT commit this file to version control.",
        "# Copy .env.example to .env and fill in the actual values.",
        f"# {'=' * 67}",
        "",
        "# Server",
        "SERVER_PORT=8080",
        "",
        "# Database",
    ]

    if database.lower() == "mongo":
        lines.append("MONGODB_URI=mongodb://localhost:27017/mydb")
    else:
        lines += ["R2DBC_URL=r2dbc:postgresql://localhost:5432/mydb", "DB_USERNAME=postgres", "DB_PASSWORD=password"]

    if messaging_system.lower() in ("rabbit-producer", "rabbit-consumer"):
        lines += [
            "",
            "# RabbitMQ",
            "RABBITMQ_HOST=localhost",
            "RABBITMQ_PORT=5672",
            "RABBITMQ_USERNAME=guest",
            "RABBITMQ_PASSWORD=guest",
        ]

    if messaging_system.lower() == "kafka-producer":
        lines += [
            "",
            "# Kafka",
            "KAFKA_BOOTSTRAP_SERVERS=localhost:9092",
        ]
    elif messaging_system.lower() == "kafka-consumer":
        lines += [
            "",
            "# Kafka",
            "KAFKA_BOOTSTRAP_SERVERS=localhost:9092",
            "KAFKA_CONSUMER_GROUP_ID=my-group",
        ]

    return "\n".join(lines) + "\n"


def get_env_example_content(project_name: str, database: str, messaging_system: str) -> str:
    lines = [
        f"# {'=' * 67}",
        f"# Environment Variables Template - {project_name}",
        f"# {'=' * 67}",
        "# Copy this file to .env and fill in the actual values.",
        f"# {'=' * 67}",
        "",
        "# Server",
        "SERVER_PORT=8080",
        "",
        "# Database",
    ]

    if database.lower() == "mongo":
        lines.append("MONGODB_URI=mongodb://localhost:27017/mydb")
    else:
        lines += ["R2DBC_URL=r2dbc:postgresql://localhost:5432/mydb", "DB_USERNAME=", "DB_PASSWORD="]

    if messaging_system.lower() in ("rabbit-producer", "rabbit-consumer"):
        lines += [
            "",
            "# RabbitMQ",
            "RABBITMQ_HOST=localhost",
            "RABBITMQ_PORT=5672",
            "RABBITMQ_USERNAME=",
            "RABBITMQ_PASSWORD=",
        ]

    if messaging_system.lower() == "kafka-producer":
        lines += [
            "",
            "# Kafka",
            "KAFKA_BOOTSTRAP_SERVERS=localhost:9092",
        ]
    elif messaging_system.lower() == "kafka-consumer":
        lines += [
            "",
            "# Kafka",
            "KAFKA_BOOTSTRAP_SERVERS=localhost:9092",
            "KAFKA_CONSUMER_GROUP_ID=",
        ]

    return "\n".join(lines) + "\n"


def get_dockerfile_content(database: str, messaging_system: str) -> str:
    db_module = "mongo" if database.lower() == "mongo" else "postgres"

    copy_poms = [
        "COPY domain/model/pom.xml domain/model/",
        "COPY application/use-cases/pom.xml application/use-cases/",
        f"COPY infrastructure/driven-adapters/{db_module}/pom.xml infrastructure/driven-adapters/{db_module}/",
        "COPY infrastructure/entry-points/rest-api/pom.xml infrastructure/entry-points/rest-api/",
        "COPY infrastructure/entry-points/app/pom.xml infrastructure/entry-points/app/",
    ]
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
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
"""


def get_jenkinsfile_content(project_name: str, database: str) -> str:
    """Jenkinsfile declarativo genérico parametrizado por servicio.

    Delega en la Shared Library `jenkins-shared-library` y se mantiene mínimo:
    el mismo pipeline sirve para todos los microservicios cambiando solo los
    parámetros.
    """
    db_type = "mongo" if database.lower() == "mongo" else "postgres"

    template = """\
@Library('jenkins-shared-library@main') _

// ───────────────────────────────────────────────────────────────────────────
// Jenkinsfile genérico (backend) — parametrizado por servicio.
// El mismo pipeline sirve para todos los microservicios; solo cambian los
// parámetros, que se resuelven en runtime. La lógica vive en la Shared Library
// (vars/) para mantener este archivo mínimo.
//
// Modelo de agentes: Kubernetes plugin. Todo el pipeline corre en un único pod
// efímero en EKS (definido en org/flexicredit/podBackend.yaml de la Shared
// Library), por lo que el workspace se comparte entre stages sin stash/unstash.
// El pod usa el ServiceAccount 'jenkins-agent' (IRSA) para autenticar kaniko
// (push a ECR). El despliegue NO ocurre aquí: este pipeline es CI y su frontera
// con el CD es escribir el nuevo image tag en Git (bumpImageTag). El CD lo hace
// ArgoCD por GitOps (auto-sync en dev/staging; sync manual en prod). Ver el
// módulo Terraform 'argocd'.
// ───────────────────────────────────────────────────────────────────────────

pipeline {
    agent {
        kubernetes {
            defaultContainer 'maven'
            yaml libraryResource('org/flexicredit/podBackend.yaml')
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
            description: 'Nombre del microservicio (deriva el repo ECR y el deployment).'
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
        ECR_REPO      = "${params.SERVICE_NAME}"
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

        // 4 — Análisis estático + quality gate (SonarQube). Falla si gate = ERROR.
        stage('Quality Gate (SonarQube)') {
            steps { runQualityGates() }
        }

        // 5 — OWASP Dependency Check + escaneo de secretos (gitleaks).
        stage('Security Scans') {
            steps { runSecurityScans() }
        }

        // 6 — Imagen Docker multi-stage vía Kaniko → push a Amazon ECR.
        stage('Build & Push Image') {
            steps {
                buildAndPushImage(
                    service:  env.SERVICE_NAME,
                    ecrRepo:  env.ECR_REPO,
                    imageTag: env.IMAGE_TAG
                )
            }
        }

        // 7 — Escaneo de la imagen publicada (Trivy). Falla ante CVE crítico.
        stage('Image Scan (Trivy)') {
            steps { scanImage(ecrRepo: env.ECR_REPO, imageTag: env.IMAGE_TAG) }
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
    return template.replace("__SERVICE_NAME__", project_name).replace("__DB_TYPE__", db_type)


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


def get_helm_chart_files(project_name: str) -> dict:
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

    values_yaml = """\
# Valores base. En GitOps, image.repository/tag se fijan por ambiente en
# values-<env>.yaml (los escribe el paso bumpImageTag de Jenkins y los lee ArgoCD).
replicaCount: 1

image:
  repository: ""   # <registry>/<service> — definido en values-<env>.yaml
  tag: ""          # <version>-<sha> inmutable — definido en values-<env>.yaml
  pullPolicy: IfNotPresent

service:
  type: ClusterIP
  port: 8080

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
    values_dev = image_block + """\
replicaCount: 1
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 512Mi
"""
    values_staging = image_block + """\
replicaCount: 2
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
    spec:
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
          {{- with .Values.env }}
          env:
            {{- toYaml . | nindent 12 }}
          {{- end }}
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


def get_root_pom(project_name: str, database: str, messaging_system: str) -> str:
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
    <dependencies>
        <dependency>
            <groupId>me.paulschwarz</groupId>
            <artifactId>spring-dotenv</artifactId>
            <version>4.0.0</version>
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


def get_module_pom(parent_artifact_id: str, safe_project_name: str, module_path: str) -> str:
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


def scaffold(project_name: str, database: str, messaging_system: str) -> None:
    safe_name = project_name.replace("-", "")
    root = Path(project_name)
    logger.info("Creando proyecto: %s (db=%s, messaging=%s)", project_name, database, messaging_system)

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

    logger.info("Módulos a generar: %d", len(modules))

    for module in modules:
        logger.debug("Procesando módulo: %s", module)
        module_name = module.split("/")[-1].replace("-", "")
        base_package = f"com.{safe_name}.{module_name}"
        package_path = "/src/main/java/" + base_package.replace(".", "/")

        pkg_dir = root / (module + package_path)
        pkg_dir.mkdir(parents=True, exist_ok=True)

        pom_path = root / module / "pom.xml"
        pom_path.write_text(get_module_pom(project_name, safe_name, module))
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
            (resources_dir / "application.yml").write_text(get_yaml_content(database, messaging_system))
            logger.debug("application.yml creado en: %s", resources_dir)

        logger.info("Módulo listo: %s", module)

    if messaging_system.lower() == "rabbit-producer":
        create_rabbit_producer_files(root, safe_name)
    elif messaging_system.lower() == "rabbit-consumer":
        create_rabbit_consumer_files(root, safe_name)
    elif messaging_system.lower() == "kafka-producer":
        create_kafka_producer_files(root, safe_name)
    elif messaging_system.lower() == "kafka-consumer":
        create_kafka_consumer_files(root, safe_name)

    (root / ".env").write_text(get_env_content(project_name, database, messaging_system))
    logger.debug(".env creado")
    (root / ".env.example").write_text(get_env_example_content(project_name, database, messaging_system))
    logger.debug(".env.example creado")

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
.env
"""
    (root / ".gitignore").write_text(gitignore)
    logger.debug(".gitignore creado")
    (root / "pom.xml").write_text(get_root_pom(project_name, database, messaging_system))
    logger.debug("pom.xml raíz creado")

    (root / "Dockerfile").write_text(get_dockerfile_content(database, messaging_system))
    logger.debug("Dockerfile creado")
    (root / ".dockerignore").write_text(get_dockerignore_content())
    logger.debug(".dockerignore creado")

    (root / "Jenkinsfile").write_text(get_jenkinsfile_content(project_name, database))
    logger.debug("Jenkinsfile creado")

    # Helm chart consumido por deployToEks() de la Shared Library.
    helm_root = root / "helm" / project_name
    for rel_path, content in get_helm_chart_files(project_name).items():
        target = helm_root / rel_path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
    logger.debug("Helm chart creado en %s", helm_root)

    logger.info("Proyecto creado exitosamente en: %s", root.resolve())
    _print_run_instructions(project_name, root, messaging_system)


def _print_run_instructions(project_name: str, root: Path, messaging_system: str) -> None:
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

 2. Configura las variables de entorno:
    cp .env.example .env
    # Edita .env con tus credenciales reales
{rabbit_note}
 3. Compila el proyecto:
    mvn clean install -DskipTests

 4. Ejecuta la aplicación:
    mvn -pl infrastructure/entry-points/app spring-boot:run

 5. Verifica que está corriendo:
    curl http://localhost:8080/hello

 ── Ejecución con Docker ───────────────────────────────────────────────

    # Construir la imagen
    docker build -t {project_name}:latest .

    # Ejecutar pasando variables de entorno desde .env
    docker run -d --name {project_name} \\
      --env-file .env \\
      -p 8080:8080 \\
      {project_name}:latest

 Verificar contenedor:
    docker logs -f {project_name}
    curl http://localhost:8080/hello

 Detener y eliminar:
    docker rm -f {project_name}

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
        scaffold(args.service_name, args.database, args.messaging_system)
    except OSError as e:
        logger.error("No se pudo crear el proyecto: %s", e)
        sys.exit(1)


if __name__ == "__main__":
    main()
