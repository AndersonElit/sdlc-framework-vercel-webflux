#!/usr/bin/env python3
"""Genera el microservicio `integration-service`: capa de integración (Apache Camel)
y orquestador de saga (Camel Saga EIP + coordinador Narayana LRA), con arquitectura
hexagonal reactiva (Spring WebFlux), consistente con `maven_hexagonal_scaffold.py`.

Reutiliza los helpers genéricos del scaffold base (Jenkinsfile, Helm, Dockerignore,
edición de Terraform, push a Gitea, ApplicationSet de ArgoCD) e implementa los módulos
propios de integración y saga.
"""

import argparse
import logging
import sys
from pathlib import Path

# Reutiliza el scaffold base como módulo (vive en el mismo directorio).
sys.path.insert(0, str(Path(__file__).resolve().parent))
import maven_hexagonal_scaffold as base  # noqa: E402

logger = logging.getLogger(__name__)

# Versión LTS de Apache Camel compatible con Spring Boot 3.4.x (Fase 0 del plan).
CAMEL_VERSION = "4.10.2"


def _cap(name: str) -> str:
    """`buro-credito` -> `BuroCredito` (para nombres de clase Java)."""
    return "".join(part.capitalize() for part in name.replace("_", "-").split("-"))


def _java_id(name: str) -> str:
    """`buro-credito` -> `burocredito` (segmento de paquete / id en minúscula)."""
    return name.replace("_", "").replace("-", "").lower()


# ─────────────────────────────────────────────────────────────────────────────
# POM raíz (con BOM de Camel y todos los módulos)
# ─────────────────────────────────────────────────────────────────────────────

def get_integration_root_pom(project_name: str, safe_name: str, modules: list[str]) -> str:
    modules_xml = "\n".join(f"        <module>{m}</module>" for m in modules)
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
        <camel.version>{CAMEL_VERSION}</camel.version>
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
            <dependency>
                <groupId>org.apache.camel.springboot</groupId>
                <artifactId>camel-spring-boot-bom</artifactId>
                <version>${{camel.version}}</version>
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


# ─────────────────────────────────────────────────────────────────────────────
# POMs de módulos Camel/Saga/App (los que el scaffold base no conoce)
# ─────────────────────────────────────────────────────────────────────────────

def _module_pom_header(parent_artifact_id: str, safe: str, module_path: str) -> str:
    module_artifact_id = module_path.replace("/", "-")
    module_package_name = module_path.split("/")[-1].replace("-", "")
    rel = "../../../pom.xml" if module_path.startswith("infrastructure/") else "../../pom.xml"
    return f"""\
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
    <modelVersion>4.0.0</modelVersion>
    <parent>
        <groupId>com.{safe}</groupId>
        <artifactId>{parent_artifact_id}</artifactId>
        <version>0.0.1-SNAPSHOT</version>
        <relativePath>{rel}</relativePath>
    </parent>
    <groupId>com.{safe}.{module_package_name}</groupId>
    <artifactId>{module_artifact_id}</artifactId>
    <dependencies>
"""


def _domain_dep(safe: str) -> str:
    return f"""\
        <dependency>
            <groupId>com.{safe}.model</groupId>
            <artifactId>domain-model</artifactId>
            <version>${{project.version}}</version>
        </dependency>
"""


def get_camel_rest_consumer_pom(parent_artifact_id: str, safe: str) -> str:
    deps = _domain_dep(safe) + """\
        <dependency>
            <groupId>org.apache.camel.springboot</groupId>
            <artifactId>camel-spring-boot-starter</artifactId>
        </dependency>
        <dependency>
            <groupId>org.apache.camel.springboot</groupId>
            <artifactId>camel-http-starter</artifactId>
        </dependency>
        <dependency>
            <groupId>org.apache.camel.springboot</groupId>
            <artifactId>camel-rest-starter</artifactId>
        </dependency>
        <dependency>
            <groupId>org.apache.camel.springboot</groupId>
            <artifactId>camel-jackson-starter</artifactId>
        </dependency>
        <dependency>
            <groupId>org.apache.camel.springboot</groupId>
            <artifactId>camel-reactive-streams-starter</artifactId>
        </dependency>
        <dependency>
            <groupId>org.apache.camel.springboot</groupId>
            <artifactId>camel-resilience4j-starter</artifactId>
        </dependency>
        <dependency>
            <groupId>org.apache.camel</groupId>
            <artifactId>camel-test-spring-junit5</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.wiremock</groupId>
            <artifactId>wiremock-standalone</artifactId>
            <version>3.9.1</version>
            <scope>test</scope>
        </dependency>
"""
    return _module_pom_header(parent_artifact_id, safe, "infrastructure/driven-adapters/camel-rest-consumer") + deps + "    </dependencies>\n</project>\n"


def get_saga_camel_pom(parent_artifact_id: str, safe: str) -> str:
    deps = _domain_dep(safe) + """\
        <dependency>
            <groupId>org.apache.camel.springboot</groupId>
            <artifactId>camel-spring-boot-starter</artifactId>
        </dependency>
        <dependency>
            <groupId>org.apache.camel.springboot</groupId>
            <artifactId>camel-saga-starter</artifactId>
        </dependency>
        <dependency>
            <groupId>org.apache.camel.springboot</groupId>
            <artifactId>camel-lra-starter</artifactId>
        </dependency>
        <dependency>
            <groupId>org.apache.camel.springboot</groupId>
            <artifactId>camel-reactive-streams-starter</artifactId>
        </dependency>
        <dependency>
            <groupId>org.apache.camel</groupId>
            <artifactId>camel-test-spring-junit5</artifactId>
            <scope>test</scope>
        </dependency>
"""
    return _module_pom_header(parent_artifact_id, safe, "infrastructure/driven-adapters/saga-camel") + deps + "    </dependencies>\n</project>\n"


def get_integration_app_pom(parent_artifact_id: str, safe: str, modules: list[str]) -> str:
    """El `app` ensambla todos los adaptadores/entry-points para que sus beans carguen."""
    infra = [m for m in modules if m.startswith("infrastructure/") and not m.endswith("/app")]
    dep_blocks = []
    for m in infra:
        artifact = m.replace("/", "-")
        pkg = m.split("/")[-1].replace("-", "")
        dep_blocks.append(f"""\
        <dependency>
            <groupId>com.{safe}.{pkg}</groupId>
            <artifactId>{artifact}</artifactId>
            <version>${{project.version}}</version>
        </dependency>""")
    deps = "\n".join(dep_blocks) + "\n"
    return _module_pom_header(parent_artifact_id, safe, "infrastructure/entry-points/app") + deps + """\
    </dependencies>
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
</project>
"""


# ─────────────────────────────────────────────────────────────────────────────
# application.yml propio (r2dbc + kafka producer/consumer + camel.lra + externos)
# ─────────────────────────────────────────────────────────────────────────────

def get_integration_yaml(project_name: str, port: int, org: str, externals: list[str]) -> str:
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
        "  r2dbc:",
        "    url: ${R2DBC_URL}",
        "    username: ${DB_USERNAME}",
        "    password: ${DB_PASSWORD}",
        "  kafka:",
        "    bootstrap-servers: ${KAFKA_BOOTSTRAP_SERVERS}",
        "    producer:",
        "      key-serializer: org.apache.kafka.common.serialization.StringSerializer",
        "      value-serializer: org.springframework.kafka.support.serializer.JsonSerializer",
        "    consumer:",
        f"      group-id: ${{KAFKA_CONSUMER_GROUP_ID:{project_name}-group}}",
        "      auto-offset-reset: earliest",
        "      key-deserializer: org.apache.kafka.common.serialization.StringDeserializer",
        "      value-deserializer: org.springframework.kafka.support.serializer.JsonDeserializer",
        "      properties:",
        "        spring.json.trusted.packages: '*'",
        "camel:",
        "  lra:",
        "    coordinator-url: ${LRA_COORDINATOR_URL}",
        "external:",
    ]
    for name in externals:
        lines.append(f"  {name}:")
        lines.append(f"    base-url: ${{EXT_{name.upper().replace('-', '_')}_BASE_URL}}")
    lines += ["server:", f"  port: ${{SERVER_PORT:{port}}}"]
    return "\n".join(lines) + "\n"


def get_integration_secrets_script(project_name: str, port: int, org: str, externals: list[str]) -> str:
    import json
    secret = {
        "SERVER_PORT": str(port),
        "R2DBC_URL": "r2dbc:postgresql://localhost:5432/mydb",
        "DB_USERNAME": "postgres",
        "DB_PASSWORD": "change_me",
        "KAFKA_BOOTSTRAP_SERVERS": "localhost:9092",
        "KAFKA_CONSUMER_GROUP_ID": f"{project_name}-group",
        "LRA_COORDINATOR_URL": "http://localhost:50000/lra-coordinator",
    }
    for name in externals:
        secret[f"EXT_{name.upper().replace('-', '_')}_BASE_URL"] = f"http://localhost:9999/{name}"
    secret_json = json.dumps(secret)
    return f"""\
#!/usr/bin/env bash
# Crea (o actualiza) el secret de desarrollo del integration-service en floci.
SECRET_NAME="{org}/dev/{project_name}"
ENDPOINT="http://localhost:4566"
REGION="us-east-1"

if aws --endpoint-url="$ENDPOINT" secretsmanager describe-secret \\
       --secret-id "$SECRET_NAME" --region "$REGION" &>/dev/null; then
    aws --endpoint-url="$ENDPOINT" secretsmanager put-secret-value \\
        --secret-id "$SECRET_NAME" --secret-string '{secret_json}' --region "$REGION"
    echo "Secret actualizado: $SECRET_NAME"
else
    aws --endpoint-url="$ENDPOINT" secretsmanager create-secret \\
        --name "$SECRET_NAME" --secret-string '{secret_json}' --region "$REGION"
    echo "Secret creado: $SECRET_NAME"
fi
"""


# ─────────────────────────────────────────────────────────────────────────────
# Dockerfile propio (incluye todos los módulos)
# ─────────────────────────────────────────────────────────────────────────────

def get_integration_dockerfile(modules: list[str], port: int) -> str:
    copy_poms = ["COPY pom.xml ."] + [f"COPY {m}/pom.xml {m}/" for m in modules]
    copy_poms_str = "\n".join(copy_poms)
    return f"""\
# ── Build stage ────────────────────────────────────────────────────────
FROM maven:3.9-eclipse-temurin-21-alpine AS builder
WORKDIR /app
{copy_poms_str}
RUN mvn dependency:go-offline -B --no-transfer-progress
COPY . .
RUN mvn clean package -DskipTests --no-transfer-progress

# ── Runtime stage ───────────────────────────────────────────────────────
FROM eclipse-temurin:21-jre-alpine
WORKDIR /app
COPY --from=builder /app/infrastructure/entry-points/app/target/*.jar app.jar
EXPOSE {port}
ENTRYPOINT ["java", "-jar", "app.jar"]
"""


# ─────────────────────────────────────────────────────────────────────────────
# Generación de fuentes Java
# ─────────────────────────────────────────────────────────────────────────────

def _write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    logger.debug("Archivo creado: %s", path)


def generate_domain_sources(root: Path, safe: str, externals: list[str], flows: list[str]) -> None:
    base_pkg = f"com.{safe}.model"
    pkg_dir = root / "domain/model/src/main/java" / base_pkg.replace(".", "/")

    # Puerto coordinador de saga
    _write(pkg_dir / "SagaCoordinatorPort.java", f"""\
package {base_pkg};

import reactor.core.publisher.Mono;

/** Puerto secundario de coordinación de saga (implementado por el adaptador Camel/LRA). */
public interface SagaCoordinatorPort {{
    Mono<String> begin(String sagaType, Object payload);
    Mono<Void> complete(String sagaId);
    Mono<Void> compensate(String sagaId);
}}
""")

    # Puertos a sistemas externos + DTOs de dominio (ACL traduce hacia estos tipos)
    for name in externals:
        cls = _cap(name)
        _write(pkg_dir / f"{cls}Gateway.java", f"""\
package {base_pkg};

import reactor.core.publisher.Mono;

/** Puerto secundario hacia el sistema externo '{name}'. El dominio no conoce Camel. */
public interface {cls}Gateway {{
    Mono<{cls}Resultado> consultar({cls}Consulta consulta);
}}
""")
        _write(pkg_dir / f"{cls}Consulta.java", f"""\
package {base_pkg};

/** Solicitud de dominio hacia '{name}' (modelo propio, no del sistema externo). */
public record {cls}Consulta(String referencia, java.util.Map<String, Object> datos) {{}}
""")
        _write(pkg_dir / f"{cls}Resultado.java", f"""\
package {base_pkg};

/** Respuesta de dominio desde '{name}' (traducida por el ACL del adaptador). */
public record {cls}Resultado(String referencia, String estado, java.util.Map<String, Object> datos) {{}}
""")


def generate_usecase_sources(root: Path, safe: str, flows: list[str]) -> None:
    base_pkg = f"com.{safe}.usecases"
    pkg_dir = root / "application/use-cases/src/main/java" / base_pkg.replace(".", "/")
    model_pkg = f"com.{safe}.model"
    for flow in flows:
        cls = _cap(flow)
        _write(pkg_dir / f"{cls}SagaUseCase.java", f"""\
package {base_pkg};

import {model_pkg}.SagaCoordinatorPort;
import reactor.core.publisher.Mono;

/**
 * Orquesta la saga '{flow}'. Define la intención de negocio; la secuencia de pasos y
 * compensaciones se materializa en la ruta Camel Saga del adaptador. No conoce Camel ni LRA.
 */
public class {cls}SagaUseCase {{

    private final SagaCoordinatorPort coordinator;

    public {cls}SagaUseCase(SagaCoordinatorPort coordinator) {{
        this.coordinator = coordinator;
    }}

    public Mono<String> ejecutar(Object payload) {{
        return coordinator.begin("{flow}", payload);
    }}
}}
""")


def generate_camel_rest_consumer_sources(root: Path, safe: str, externals: list[str]) -> None:
    base_pkg = f"com.{safe}.camelrestconsumer"
    pkg_dir = root / "infrastructure/driven-adapters/camel-rest-consumer/src/main/java" / base_pkg.replace(".", "/")
    model_pkg = f"com.{safe}.model"

    for name in externals:
        cls = _cap(name)
        endpoint = f"direct:{_java_id(name)}"
        prop = name  # clave en external.<name>.base-url
        _write(pkg_dir / f"{cls}RouteBuilder.java", f"""\
package {base_pkg};

import org.apache.camel.builder.RouteBuilder;
import org.springframework.stereotype.Component;

/**
 * Ruta Camel hacia el sistema externo '{name}' con ACL, reintentos y circuit breaker
 * (Resilience4j). Bridge reactivo en el adaptador; aquí solo mediación e integración.
 */
@Component
public class {cls}RouteBuilder extends RouteBuilder {{

    @Override
    public void configure() {{
        onException(Exception.class)
                .maximumRedeliveries(3)
                .redeliveryDelay(500)
                .handled(true)
                .setBody(constant(null));

        from("{endpoint}")
                .routeId("{prop}-route")
                .marshal().json()
                .circuitBreaker()
                    .resilience4jConfiguration()
                        .timeoutEnabled(true)
                        .timeoutDuration(3000)
                    .end()
                    .setHeader("CamelHttpMethod", constant("POST"))
                    .toD("{{{{external.{prop}.base-url}}}}/consulta?bridgeEndpoint=true&throwExceptionOnFailure=true")
                .endCircuitBreaker()
                .unmarshal().json();
    }}
}}
""")
        _write(pkg_dir / f"{cls}CamelAdapter.java", f"""\
package {base_pkg};

import {model_pkg}.{cls}Consulta;
import {model_pkg}.{cls}Gateway;
import {model_pkg}.{cls}Resultado;
import org.apache.camel.ProducerTemplate;
import org.springframework.stereotype.Component;
import reactor.core.publisher.Mono;

/** Implementa el puerto {cls}Gateway invocando la ruta Camel. Bridge a Reactor con CompletableFuture. */
@Component
public class {cls}CamelAdapter implements {cls}Gateway {{

    private final ProducerTemplate producerTemplate;

    public {cls}CamelAdapter(ProducerTemplate producerTemplate) {{
        this.producerTemplate = producerTemplate;
    }}

    @Override
    public Mono<{cls}Resultado> consultar({cls}Consulta consulta) {{
        return Mono.fromFuture(
                producerTemplate.asyncRequestBody("{endpoint}", consulta, {cls}Resultado.class));
    }}
}}
""")


def generate_saga_camel_sources(root: Path, safe: str, flows: list[str], externals: list[str]) -> None:
    base_pkg = f"com.{safe}.sagacamel"
    pkg_dir = root / "infrastructure/driven-adapters/saga-camel/src/main/java" / base_pkg.replace(".", "/")
    model_pkg = f"com.{safe}.model"

    # Configuración del servicio LRA (Narayana) que respalda el Saga EIP
    _write(pkg_dir / "LraSagaConfig.java", f"""\
package {base_pkg};

import org.apache.camel.service.lra.LRASagaService;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/** Registra el servicio de saga LRA (coordinador Narayana) usado por el Saga EIP de Camel. */
@Configuration
public class LraSagaConfig {{

    @Bean
    public LRASagaService lraSagaService(
            @Value("${{camel.lra.coordinator-url}}") String coordinatorUrl,
            @Value("${{server.port:8090}}") int localPort) {{
        LRASagaService service = new LRASagaService();
        service.setCoordinatorUrl(coordinatorUrl);
        service.setLocalParticipantUrl("http://localhost:" + localPort);
        return service;
    }}
}}
""")

    # Adaptador que implementa el puerto de coordinación
    first_flow = flows[0] if flows else "default"
    _write(pkg_dir / "CamelSagaCoordinatorAdapter.java", f"""\
package {base_pkg};

import {model_pkg}.SagaCoordinatorPort;
import org.apache.camel.ProducerTemplate;
import org.springframework.stereotype.Component;
import reactor.core.publisher.Mono;

import java.util.UUID;

/** Implementa SagaCoordinatorPort delegando en las rutas Camel Saga (respaldadas por LRA). */
@Component
public class CamelSagaCoordinatorAdapter implements SagaCoordinatorPort {{

    private final ProducerTemplate producerTemplate;

    public CamelSagaCoordinatorAdapter(ProducerTemplate producerTemplate) {{
        this.producerTemplate = producerTemplate;
    }}

    @Override
    public Mono<String> begin(String sagaType, Object payload) {{
        String sagaId = UUID.randomUUID().toString();
        return Mono.fromRunnable(() ->
                producerTemplate.sendBodyAndHeader("direct:saga-" + sagaType, payload, "sagaId", sagaId))
                .thenReturn(sagaId);
    }}

    @Override
    public Mono<Void> complete(String sagaId) {{
        return Mono.empty();
    }}

    @Override
    public Mono<Void> compensate(String sagaId) {{
        return Mono.fromRunnable(() ->
                producerTemplate.sendBodyAndHeader("direct:compensar-{first_flow}", null, "sagaId", sagaId))
                .then();
    }}
}}
""")

    # Una ruta de saga por flujo, con su compensación
    for flow in flows:
        fid = _java_id(flow)
        _write(pkg_dir / f"{_cap(flow)}SagaRouteBuilder.java", f"""\
package {base_pkg};

import org.apache.camel.builder.RouteBuilder;
import org.springframework.stereotype.Component;

/**
 * Saga '{flow}' (orquestación). El Saga EIP delimita la transacción de larga duración (LRA);
 * cada paso declara su compensación. Completar los pasos según el diseño técnico.
 */
@Component
public class {_cap(flow)}SagaRouteBuilder extends RouteBuilder {{

    @Override
    public void configure() {{
        from("direct:saga-{flow}")
                .routeId("saga-{flow}")
                .saga()
                    .compensation("direct:compensar-{flow}")
                    .log("Saga '{flow}' iniciada: ${{header.sagaId}}");
                    // TODO: encadenar los pasos de la saga (to("direct:<paso>")) según el diseño.

        from("direct:compensar-{flow}")
                .routeId("compensar-{flow}")
                .log("Compensando saga '{flow}': ${{header.sagaId}}");
                // TODO: invocar los endpoints/consumidores de compensación de los participantes.
    }}
}}
""")


def generate_app_sources(root: Path, safe: str, flows: list[str]) -> None:
    main_pkg = f"com.{safe}"
    main_dir = root / "infrastructure/entry-points/app/src/main/java" / main_pkg.replace(".", "/")
    usecases_pkg = f"com.{safe}.usecases"
    model_pkg = f"com.{safe}.model"

    _write(main_dir / "MainApplication.java", f"""\
package {main_pkg};

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication(scanBasePackages = "{main_pkg}")
public class MainApplication {{
    public static void main(String[] args) {{
        SpringApplication.run(MainApplication.class, args);
    }}
}}
""")

    bean_methods = []
    for flow in flows:
        cls = _cap(flow)
        bean_methods.append(f"""\
    @Bean
    public {cls}SagaUseCase {_java_id(flow)}SagaUseCase(SagaCoordinatorPort coordinator) {{
        return new {cls}SagaUseCase(coordinator);
    }}""")
    beans = "\n\n".join(bean_methods) if bean_methods else "    // Sin flujos de saga definidos."
    imports = "\n".join(f"import {usecases_pkg}.{_cap(f)}SagaUseCase;" for f in flows)

    _write(main_dir / "UseCasesConfig.java", f"""\
package {main_pkg};

import {model_pkg}.SagaCoordinatorPort;
{imports}
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/** Expone los casos de uso (dominio limpio de Spring) como beans, inyectando los puertos. */
@Configuration
public class UseCasesConfig {{

{beans}
}}
""")

    resources = root / "infrastructure/entry-points/app/src/main/resources"
    resources.mkdir(parents=True, exist_ok=True)
    (resources / "application-dev.yml").write_text(base.get_dev_yaml_content())


# ─────────────────────────────────────────────────────────────────────────────
# Orquestación del scaffold
# ─────────────────────────────────────────────────────────────────────────────

def scaffold_integration(project_name: str, externals: list[str], flows: list[str],
                         port: int, org: str) -> None:
    safe = project_name.replace("-", "")
    root = Path(project_name)
    logger.info("Creando %s (externos=%s, sagas=%s, port=%d)", project_name, externals, flows, port)

    modules = [
        "domain/model",
        "application/use-cases",
        "infrastructure/driven-adapters/postgres",
        "infrastructure/driven-adapters/kafka-producer",
        "infrastructure/driven-adapters/camel-rest-consumer",
        "infrastructure/driven-adapters/saga-camel",
        "infrastructure/entry-points/rest-api",
        "infrastructure/entry-points/kafka-consumer",
        "infrastructure/entry-points/app",
    ]

    # POMs y esqueleto de paquetes
    for module in modules:
        module_dir = root / module
        pkg = module.split("/")[-1].replace("-", "")
        (module_dir / "src/main/java" / f"com/{safe}/{pkg}").mkdir(parents=True, exist_ok=True)

        if module == "infrastructure/driven-adapters/camel-rest-consumer":
            (module_dir / "pom.xml").write_text(get_camel_rest_consumer_pom(project_name, safe))
        elif module == "infrastructure/driven-adapters/saga-camel":
            (module_dir / "pom.xml").write_text(get_saga_camel_pom(project_name, safe))
        elif module == "infrastructure/entry-points/app":
            (module_dir / "pom.xml").write_text(get_integration_app_pom(project_name, safe, modules))
        else:
            # domain/model, use-cases, postgres, kafka-producer, rest-api, kafka-consumer
            (module_dir / "pom.xml").write_text(base.get_module_pom(project_name, safe, module))

    # Fuentes Kafka (producer de comandos + consumer de respuestas) reutilizando el base
    base.create_kafka_producer_files(root, safe)
    base.create_kafka_consumer_files(root, safe)

    # rest-api mínimo (API interna de saga; los endpoints reales se añaden bajo TDD)
    restapi_pkg = f"com.{safe}.restapi"
    restapi_dir = root / "infrastructure/entry-points/rest-api/src/main/java" / restapi_pkg.replace(".", "/")
    _write(restapi_dir / "IntegrationHealthController.java", f"""\
package {restapi_pkg};

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import reactor.core.publisher.Mono;

@RestController
public class IntegrationHealthController {{
    @GetMapping("/integration/ping")
    public Mono<String> ping() {{
        return Mono.just("integration-service up");
    }}
}}
""")

    # Fuentes propias
    generate_domain_sources(root, safe, externals, flows)
    generate_usecase_sources(root, safe, flows)
    generate_camel_rest_consumer_sources(root, safe, externals)
    generate_saga_camel_sources(root, safe, flows, externals)
    generate_app_sources(root, safe, flows)

    # application.yml en el módulo app
    app_resources = root / "infrastructure/entry-points/app/src/main/resources"
    app_resources.mkdir(parents=True, exist_ok=True)
    (app_resources / "application.yml").write_text(get_integration_yaml(project_name, port, org, externals))

    # POM raíz, Dockerfile, .dockerignore, Jenkinsfile, Helm, secrets, gitignore
    (root / "pom.xml").write_text(get_integration_root_pom(project_name, safe, modules))
    (root / "Dockerfile").write_text(get_integration_dockerfile(modules, port))
    (root / ".dockerignore").write_text(base.get_dockerignore_content())
    (root / "Jenkinsfile").write_text(base.get_jenkinsfile_content(project_name, "postgres", org))
    (root / ".gitignore").write_text("target/\n*.class\n*.log\n*.jar\n.idea/\n.vscode/\n")

    scripts_dir = root / "scripts"
    scripts_dir.mkdir(parents=True, exist_ok=True)
    secret_script = scripts_dir / "create-secrets-dev.sh"
    secret_script.write_text(get_integration_secrets_script(project_name, port, org, externals))
    secret_script.chmod(0o755)

    helm_root = root / "helm" / project_name
    for rel_path, content in base.get_helm_chart_files(project_name, port).items():
        target = helm_root / rel_path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)

    # Integración con el ecosistema (Terraform multi-ambiente, ArgoCD, Gitea)
    base._update_terraform_services(project_name)
    base._update_argocd_applicationset(project_name, org)
    base._setup_gitea_repo(project_name, root, org)

    logger.info("integration-service generado en: %s", root.resolve())
    print(f"\n[OK] {project_name} generado.")
    print(f"  Sistemas externos (rutas Camel): {', '.join(externals) or '(ninguno)'}")
    print(f"  Flujos de saga (orquestador):    {', '.join(flows) or '(ninguno)'}")
    print(f"  Coordinador de saga: Narayana LRA (camel-lra {CAMEL_VERSION})")
    print("  Compila con: mvn -q -DskipTests package")


def _parse_csv(value: str) -> list[str]:
    return [v.strip() for v in value.split(",") if v.strip()] if value else []


def _parse_externals(value: str) -> list[str]:
    """`buro=BC-01,pasarela=BC-02` -> ['buro', 'pasarela'] (el BC es trazabilidad de diseño)."""
    result = []
    for item in _parse_csv(value):
        name = item.split("=")[0].strip()
        if name:
            result.append(name)
    return result


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Scaffolder del integration-service (Apache Camel + Saga EIP/LRA).")
    parser.add_argument("-n", "--service-name", default="integration-service",
                        help="Nombre del servicio (default: integration-service).")
    parser.add_argument("--org", required=True, metavar="ORG",
                        help="Slug del proyecto (debe coincidir con el -P de los scripts).")
    parser.add_argument("-p", "--port", type=int, default=8090,
                        help="Puerto local del servicio (default: 8090).")
    parser.add_argument("--external-systems", default="",
                        help="Sistemas externos: 'nombre=BC-XX,nombre2=BC-YY' (rutas Camel).")
    parser.add_argument("--saga-flows", default="",
                        help="Flujos de saga a orquestar: 'flujo1,flujo2' (un orquestador por flujo).")
    parser.add_argument("-v", "--verbose", action="store_true", help="Logs de depuración.")
    args = parser.parse_args()

    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s %(message)s")

    externals = _parse_externals(args.external_systems)
    flows = _parse_csv(args.saga_flows)
    scaffold_integration(args.service_name, externals, flows, args.port, args.org)


if __name__ == "__main__":
    main()
