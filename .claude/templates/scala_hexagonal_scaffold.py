#!/usr/bin/env python3
"""Genera un proyecto base Scala (sbt) multimódulo con arquitectura hexagonal y batch Spark.

Modo genérico (sin --report-role): arquetipo batch vacío (placeholders + BatchMain vacío).
Modo reportería (--report-role extraction|processing): genera el subsistema ETL Spark
descrito en PLAN-reporteria-spark-etl.md (§7.1.1), con adaptadores Mongo (read model CQRS) /
JDBC / S3-parquet / Kafka y el patrón Factory de transformadores (DR-10).
"""

import argparse
import logging
import re
import sys
from pathlib import Path

logger = logging.getLogger(__name__)


# --------------------------------------------------------------------------- #
# build.sbt
# --------------------------------------------------------------------------- #
def build_files(root: Path, svc: str, pkg: str,
                report_role: str | None = None,
                source: str = "mongo") -> None:
    write(root, "project/build.properties", "sbt.version=1.9.8\n")

    write(root, "project/plugins.sbt",
          'addSbtPlugin("com.eed3si9n" % "sbt-assembly" % "2.1.4")\n')

    reporting = report_role is not None
    extraction_mongo = report_role == "extraction" and source == "mongo"
    processing = report_role == "processing"

    # vals de dependencias extra del modo reportería
    extra_vals = ""
    if reporting:
        extra_vals += (
            'val kafka = Seq("org.apache.kafka" % "kafka-clients" % "3.7.0")\n'
        )
    if extraction_mongo:
        extra_vals += (
            'val mongo = Seq("org.mongodb.spark" %% "mongo-spark-connector" % "10.3.0")\n'
        )

    # listas de dependencias por módulo
    driven_libs = "catsEffect ++ spark ++ hadoop"
    if reporting:
        driven_libs += " ++ kafka"
    if extraction_mongo:
        driven_libs += " ++ mongo"

    entry_extra = " ++ logging"
    if processing:
        entry_extra += " ++ kafka"

    write(root, "build.sbt",
          'ThisBuild / organization := "com.example"\n'
          'ThisBuild / version      := "0.1.0-SNAPSHOT"\n'
          'ThisBuild / scalaVersion := "2.13.14"\n'
          "\n"
          'ThisBuild / scalacOptions += "-Xsource:3"\n'
          "\n"
          'val catsEffectVersion = "3.5.3"\n'
          'val logbackVersion    = "1.4.14"\n'
          'val sparkVersion      = "3.5.1"\n'
          "\n"
          'val catsEffect = Seq("org.typelevel" %% "cats-effect" % catsEffectVersion)\n'
          'val logging    = Seq("ch.qos.logback" % "logback-classic" % logbackVersion)\n'
          "val spark = Seq(\n"
          '  "org.apache.spark" %% "spark-core" % sparkVersion % "provided",\n'
          '  "org.apache.spark" %% "spark-sql"  % sparkVersion % "provided"\n'
          ")\n"
          "val hadoop = Seq(\n"
          '  "org.apache.hadoop"  % "hadoop-aws"         % "3.3.4",\n'
          '  "com.amazonaws"      % "aws-java-sdk-bundle" % "1.12.262"\n'
          ")\n"
          f"{extra_vals}"
          "\n"
          "lazy val domain = project\n"
          '  .in(file("domain/model"))\n'
          '  .settings(name := "domain", libraryDependencies ++= catsEffect ++ spark)\n'
          "\n"
          "lazy val useCases = project\n"
          '  .in(file("application/use-cases"))\n'
          '  .settings(name := "use-cases", libraryDependencies ++= catsEffect ++ spark)\n'
          "  .dependsOn(domain)\n"
          "\n"
          "lazy val drivenAdapters = project\n"
          '  .in(file("infrastructure/driven-adapters"))\n'
          "  .settings(\n"
          '    name := "driven-adapters",\n'
          f"    libraryDependencies ++= {driven_libs}\n"
          "  )\n"
          "  .dependsOn(domain)\n"
          "\n"
          "lazy val entryPoints = project\n"
          '  .in(file("infrastructure/entry-points"))\n'
          "  .settings(\n"
          '    name := "entry-points",\n'
          "    libraryDependencies ++= Seq(\n"
          '      "org.apache.spark" %% "spark-core" % sparkVersion,\n'
          '      "org.apache.spark" %% "spark-sql"  % sparkVersion\n'
          f"    ){entry_extra},\n"
          "    Compile / run / fork := true,\n"
          "    Compile / run / baseDirectory := (ThisBuild / baseDirectory).value,\n"
          "    Compile / run / javaOptions ++= Seq(\n"
          '      "--add-opens=java.base/sun.nio.ch=ALL-UNNAMED",\n'
          '      "--add-opens=java.base/java.nio=ALL-UNNAMED",\n'
          '      "--add-opens=java.base/java.lang=ALL-UNNAMED",\n'
          '      "--add-opens=java.base/java.lang.invoke=ALL-UNNAMED",\n'
          '      "--add-opens=java.base/java.lang.reflect=ALL-UNNAMED",\n'
          '      "--add-opens=java.base/java.io=ALL-UNNAMED",\n'
          '      "--add-opens=java.base/java.net=ALL-UNNAMED",\n'
          '      "--add-opens=java.base/java.util=ALL-UNNAMED",\n'
          '      "--add-opens=java.base/java.util.concurrent=ALL-UNNAMED",\n'
          '      "--add-opens=java.base/java.util.concurrent.atomic=ALL-UNNAMED",\n'
          '      "--add-opens=java.base/sun.nio.cs=ALL-UNNAMED",\n'
          '      "--add-opens=java.base/sun.security.action=ALL-UNNAMED",\n'
          '      "--add-opens=java.base/sun.util.calendar=ALL-UNNAMED",\n'
          '      "--add-opens=java.security.jgss/sun.security.krb5=ALL-UNNAMED"\n'
          "    ),\n"
          f'    Compile / run / mainClass := Some("com.example.{pkg}.infrastructure.entrypoints.BatchMain"),\n'
          f'    assembly / mainClass := Some("com.example.{pkg}.infrastructure.entrypoints.BatchMain"),\n'
          "    assembly / assemblyMergeStrategy := {\n"
          '      case PathList("META-INF", _ @ _*) => MergeStrategy.discard\n'
          "      case _                            => MergeStrategy.first\n"
          "    }\n"
          "  )\n"
          "  .dependsOn(useCases, drivenAdapters)\n"
          "\n"
          "lazy val root = project\n"
          '  .in(file("."))\n'
          "  .aggregate(domain, useCases, drivenAdapters, entryPoints)\n"
          '  .settings(name := "scala-hexagonal-architecture", publish / skip := true)\n')


# --------------------------------------------------------------------------- #
# .env
# --------------------------------------------------------------------------- #
def dotenv_files(root: Path, report_role: str | None = None,
                 source: str = "mongo") -> None:
    if report_role is None:
        content = (
            "R2_ACCOUNT_ID=\n"
            "R2_ACCESS_KEY_ID=\n"
            "R2_SECRET_ACCESS_KEY=\n"
        )
    else:
        content = (
            "# --- AWS / S3 (floci en dev, AWS real en staging/prod) ---\n"
            "AWS_ENDPOINT_URL=http://localhost:4566\n"
            "AWS_ACCESS_KEY_ID=test\n"
            "AWS_SECRET_ACCESS_KEY=test\n"
            "AWS_REGION=us-east-1\n"
            "REPORT_BUCKET=reports\n"
            "# --- Kafka ---\n"
            "KAFKA_BOOTSTRAP_SERVERS=localhost:9092\n"
        )
        if report_role == "extraction" and source == "mongo":
            content += (
                "# --- Read model CQRS (MongoDB) ---\n"
                "MONGO_URI=mongodb://localhost:27017\n"
                "MONGO_READ_DB=readmodel\n"
                "MONGO_READ_COLLECTION=ventas\n"
            )
        elif report_role == "extraction" and source == "jdbc":
            content += (
                "# --- Fuente JDBC (proyectos sin CQRS) ---\n"
                "JDBC_URL=jdbc:postgresql://localhost:5432/app\n"
                "JDBC_TABLE=ventas\n"
                "JDBC_USER=app\n"
                "JDBC_PASSWORD=app\n"
            )
    write(root, ".env", content)
    write(root, ".env.example", content)


# --------------------------------------------------------------------------- #
# Generadores genéricos (modo sin --report-role) — comportamiento original
# --------------------------------------------------------------------------- #
def domain_model(root: Path, pkg: str) -> None:
    base = f"domain/model/src/main/scala/com/example/{pkg}/domain"
    write(root, f"{base}/model/.gitkeep", "")
    write(root, f"{base}/ports/.gitkeep", "")


def application_use_cases(root: Path, pkg: str) -> None:
    write(root, f"application/use-cases/src/main/scala/com/example/{pkg}/application/usecases/.gitkeep", "")


def driven_adapters(root: Path, pkg: str) -> None:
    base = f"infrastructure/driven-adapters/src/main/scala/com/example/{pkg}/infrastructure/driven"
    write(root, f"{base}/inmemory/.gitkeep", "")
    write(root, f"{base}/eventbus/.gitkeep", "")


def entry_points(root: Path, svc: str, pkg: str) -> None:
    base = f"infrastructure/entry-points/src/main/scala/com/example/{pkg}/infrastructure/entrypoints"
    full_pkg = f"com.example.{pkg}.infrastructure.entrypoints"

    write(root, f"{base}/BatchMain.scala",
          f"package {full_pkg}\n"
          "\n"
          "import org.apache.spark.sql.SparkSession\n"
          "\n"
          "object BatchMain {\n"
          "\n"
          "  def main(args: Array[String]): Unit = {\n"
          "    val argMap: Map[String, String] =\n"
          "      args.grouped(2)\n"
          '        .collect { case Array(k, v) if k.startsWith("--") => k.stripPrefix("--") -> v }\n'
          "        .toMap\n"
          "\n"
          "    val spark = SparkSession.builder\n"
          f'      .appName("{svc}")\n'
          '      .master(sys.env.getOrElse("SPARK_MASTER", "local[*]"))\n'
          "      .getOrCreate()\n"
          "\n"
          "    try {\n"
          "      run(spark, argMap)\n"
          "    } finally {\n"
          "      spark.stop()\n"
          "    }\n"
          "  }\n"
          "\n"
          "  private def run(spark: SparkSession, args: Map[String, String]): Unit = {\n"
          "    // TODO: implement batch logic\n"
          "  }\n"
          "}\n")


# --------------------------------------------------------------------------- #
# Helpers de generación de código Scala (modo reportería)
# --------------------------------------------------------------------------- #
def _r(content: str, pkg: str, **kw: str) -> str:
    """Sustituye sentinelas __PKG__/__X__ por valores reales (evita choques con `{`/`$` de Scala)."""
    out = content.replace("__PKG__", pkg)
    for k, v in kw.items():
        out = out.replace(f"__{k}__", v)
    return out


def _transformer_class(report_type: str) -> str:
    parts = [p for p in re.split(r"[-_\s]+", report_type) if p]
    return "".join(p.capitalize() for p in parts) + "Transformer"


def _scala_base(pkg: str, layer: str) -> str:
    mapping = {
        "domain.model": f"domain/model/src/main/scala/com/example/{pkg}/domain/model",
        "domain.ports": f"domain/model/src/main/scala/com/example/{pkg}/domain/ports",
        "usecases": f"application/use-cases/src/main/scala/com/example/{pkg}/application/usecases",
        "transformers": f"application/use-cases/src/main/scala/com/example/{pkg}/application/usecases/transformers",
        "driven": f"infrastructure/driven-adapters/src/main/scala/com/example/{pkg}/infrastructure/driven",
        "entry": f"infrastructure/entry-points/src/main/scala/com/example/{pkg}/infrastructure/entrypoints",
    }
    return mapping[layer]


# --------------------------------------------------------------------------- #
# Dominio (ambos roles)
# --------------------------------------------------------------------------- #
def report_domain_model(root: Path, pkg: str) -> None:
    base = _scala_base(pkg, "domain.model")
    ports = _scala_base(pkg, "domain.ports")

    write(root, f"{base}/ReportType.scala", _r('''package com.example.__PKG__.domain.model

/** Tipo de reporte (lenguaje ubicuo del bounded context de Reportería). */
final case class ReportType(value: String)

object ReportType {
  def fromString(s: String): ReportType = ReportType(s.trim.toLowerCase)
}
''', pkg))

    write(root, f"{base}/ColumnSpec.scala", _r('''package com.example.__PKG__.domain.model

/** Especificación declarativa de una columna del esquema de un reporte (DR-1). */
final case class ColumnSpec(name: String, dataType: String, nullable: Boolean)
''', pkg))

    write(root, f"{base}/IntegrityRule.scala", _r('''package com.example.__PKG__.domain.model

/** Regla de integridad declarativa. `rule` admite p.ej. "NOT_NULL", "UNIQUE", "RANGE:0:100". */
final case class IntegrityRule(column: String, rule: String)
''', pkg))

    write(root, f"{base}/ReportSchema.scala", _r('''package com.example.__PKG__.domain.model

/** Esquema declarado de un reporte: contrato y fuente de verdad de la validación (DR-1). */
final case class ReportSchema(
    reportType: ReportType,
    version: String,
    columns: List[ColumnSpec],
    integrityRules: List[IntegrityRule]
) {
  def columnNames: Set[String] = columns.map(_.name).toSet
  def notNullColumns: List[String] = columns.filterNot(_.nullable).map(_.name)
}
''', pkg))

    write(root, f"{base}/ReportEvents.scala", _r('''package com.example.__PKG__.domain.model

/** Eventos de dominio del subsistema de reportería (§6). La serialización vive en infraestructura. */
sealed trait ReportEvent { def reportId: String }

final case class ReportExtracted(
    reportId: String,
    runId: String,
    reportType: String,
    schemaVersion: String,
    rawParquetUri: String,
    rowCount: Long,
    validatedAt: String
) extends ReportEvent

final case class ReportProcessed(
    reportId: String,
    runId: String,
    reportType: String,
    processedParquetUri: String,
    formats: List[String],
    processedAt: String
) extends ReportEvent

final case class ReportFailed(
    reportId: String,
    stage: String,
    reason: String,
    failedColumns: List[String]
) extends ReportEvent
''', pkg))

    # Puertos
    write(root, f"{ports}/EventBusPort.scala", _r('''package com.example.__PKG__.domain.ports

/** Puerto de publicación de eventos. Mantiene el dominio libre de Kafka. */
trait EventBusPort {
  def publish(topic: String, key: String, payload: String): Unit
}
''', pkg))

    write(root, f"{ports}/SourceDataPort.scala", _r('''package com.example.__PKG__.domain.ports

import org.apache.spark.sql.DataFrame

/** Puerto de lectura de la fuente de datos (read model CQRS o JDBC).
 *  `DataFrame` aparece solo como detalle de la transformación tabular en la frontera (DR-10);
 *  los clientes Mongo/JDBC/Spark concretos viven exclusivamente en infraestructura. */
trait SourceDataPort {
  def read(): DataFrame
}
''', pkg))

    write(root, f"{ports}/ParquetStorePort.scala", _r('''package com.example.__PKG__.domain.ports

import org.apache.spark.sql.DataFrame

/** Puerto de lectura/escritura de parquet en almacenamiento de objetos (S3). */
trait ParquetStorePort {
  def writeRaw(reportType: String, reportId: String, df: DataFrame): String
  def readRaw(uri: String): DataFrame
  def writeProcessed(reportType: String, reportId: String, df: DataFrame): String
}
''', pkg))


# --------------------------------------------------------------------------- #
# Use case de extracción (MS1)
# --------------------------------------------------------------------------- #
def validate_extract_use_case(root: Path, pkg: str, out_topic: str) -> None:
    base = _scala_base(pkg, "usecases")
    write(root, f"{base}/ValidateAndExtractUseCase.scala", _r('''package com.example.__PKG__.application.usecases

import com.example.__PKG__.domain.model._
import com.example.__PKG__.domain.ports._
import org.apache.spark.sql.functions.col

/** MS1: valida el DataFrame de origen contra el `ReportSchema` declarado (DR-1),
 *  materializa parquet crudo en `raw/` y publica `report.extracted`.
 *  Si la validación falla ⇒ publica `report.extraction.failed` y falla rápido. */
class ValidateAndExtractUseCase(
    source: SourceDataPort,
    store: ParquetStorePort,
    events: EventBusPort,
    outTopic: String = "__OUT_TOPIC__"
) {

  def execute(schema: ReportSchema, reportId: String, runId: String): Unit = {
    val df = source.read()
    val actual = df.columns.toSet

    val missing = schema.columnNames.diff(actual)
    if (missing.nonEmpty) {
      fail(reportId, "extraction", "missing columns", missing.toList)
      throw new IllegalStateException(s"Schema validation failed: missing columns $missing")
    }

    val nullViolations = schema.notNullColumns.filter { c =>
      actual.contains(c) && df.filter(col(c).isNull).limit(1).count() > 0
    }
    if (nullViolations.nonEmpty) {
      fail(reportId, "extraction", "null values in non-nullable columns", nullViolations)
      throw new IllegalStateException(s"Integrity validation failed: nulls in $nullViolations")
    }

    val uri = store.writeRaw(schema.reportType.value, reportId, df)
    val rowCount = df.count()
    val payload =
      s"""{"reportId":"$reportId","runId":"$runId","reportType":"${schema.reportType.value}",""" +
      s""""schemaVersion":"${schema.version}","rawParquetUri":"$uri","rowCount":$rowCount,""" +
      s""""validatedAt":"${java.time.Instant.now()}"}"""
    events.publish(outTopic, reportId, payload)
  }

  private def fail(reportId: String, stage: String, reason: String, cols: List[String]): Unit = {
    val arr = cols.map(c => "\\"" + c + "\\"").mkString(",")
    val payload =
      s"""{"reportId":"$reportId","stage":"$stage","reason":"$reason","failedColumns":[$arr]}"""
    events.publish("report.extraction.failed", reportId, payload)
  }
}
''', pkg, OUT_TOPIC=out_topic))


# --------------------------------------------------------------------------- #
# Factory de transformadores (MS2, DR-10)
# --------------------------------------------------------------------------- #
def report_transformer_factory(root: Path, pkg: str, types: list[str],
                               out_topic: str) -> None:
    base = _scala_base(pkg, "usecases")
    tbase = _scala_base(pkg, "transformers")

    write(root, f"{base}/ReportTransformer.scala", _r('''package com.example.__PKG__.application.usecases

import com.example.__PKG__.domain.model.ReportType
import org.apache.spark.sql.DataFrame

/** Contrato común de transformación por tipo de reporte (DR-10). `DataFrame` es el detalle
 *  de la transformación Spark; cada tipo implementa su agregación/pivot/formato lógico. */
trait ReportTransformer {
  def reportType: ReportType
  def transform(raw: DataFrame): DataFrame
}

/** Se lanza cuando MS2 recibe un `reportType` no registrado en la factory. */
class UnsupportedReportTypeException(rt: ReportType)
    extends RuntimeException(s"Unsupported report type: ${rt.value}")
''', pkg))

    write(root, f"{base}/ReportTransformerFactory.scala", _r('''package com.example.__PKG__.application.usecases

import com.example.__PKG__.domain.model.ReportType

/** Resuelve el `ReportTransformer` concreto por `ReportType` (patrón Factory, DR-10).
 *  Añadir un tipo nuevo = añadir una clase + registrarla en `BatchMain`; sin tocar el use case. */
class ReportTransformerFactory(registry: Map[ReportType, ReportTransformer]) {
  def resolve(rt: ReportType): ReportTransformer =
    registry.getOrElse(rt, throw new UnsupportedReportTypeException(rt))
}
''', pkg))

    write(root, f"{base}/ProcessReportUseCase.scala", _r('''package com.example.__PKG__.application.usecases

import com.example.__PKG__.domain.model.ReportType
import com.example.__PKG__.domain.ports._

/** MS2: resuelve el transformer por `reportType` vía factory, transforma el parquet `raw/`
 *  y materializa `processed/`, publicando `report.processed`. */
class ProcessReportUseCase(
    factory: ReportTransformerFactory,
    store: ParquetStorePort,
    events: EventBusPort,
    outTopic: String = "__OUT_TOPIC__"
) {

  def execute(
      reportType: ReportType,
      reportId: String,
      runId: String,
      rawUri: String,
      formats: List[String]
  ): Unit = {
    try {
      val transformer = factory.resolve(reportType)
      val raw = store.readRaw(rawUri)
      val processed = transformer.transform(raw)
      val uri = store.writeProcessed(reportType.value, reportId, processed)
      val fmts = formats.map(f => "\\"" + f + "\\"").mkString(",")
      val payload =
        s"""{"reportId":"$reportId","runId":"$runId","reportType":"${reportType.value}",""" +
        s""""processedParquetUri":"$uri","formats":[$fmts],""" +
        s""""processedAt":"${java.time.Instant.now()}"}"""
      events.publish(outTopic, reportId, payload)
    } catch {
      case e: UnsupportedReportTypeException =>
        val payload =
          s"""{"reportId":"$reportId","stage":"processing","reason":"${e.getMessage}","failedColumns":[]}"""
        events.publish("report.processing.failed", reportId, payload)
        throw e
    }
  }
}
''', pkg, OUT_TOPIC=out_topic))

    for t in types:
        cls = _transformer_class(t)
        write(root, f"{tbase}/{cls}.scala", _r('''package com.example.__PKG__.application.usecases.transformers

import com.example.__PKG__.application.usecases.ReportTransformer
import com.example.__PKG__.domain.model.ReportType
import org.apache.spark.sql.DataFrame

/** Transformer del reporte `__TYPE__` (DR-10). */
class __CLASS__ extends ReportTransformer {
  override val reportType: ReportType = ReportType("__TYPE__")

  override def transform(raw: DataFrame): DataFrame = {
    // TODO: implementar la agregación/pivot/formato lógico de `__TYPE__`.
    // Una fila del resultado debe aproximarse a una celda lógica del formato final (DR-2).
    raw
  }
}
''', pkg, TYPE=t, CLASS=cls))


# --------------------------------------------------------------------------- #
# Driven adapters
# --------------------------------------------------------------------------- #
def mongo_source_adapter(root: Path, pkg: str) -> None:
    base = _scala_base(pkg, "driven")
    write(root, f"{base}/mongosource/SparkMongoSourceAdapter.scala", _r('''package com.example.__PKG__.infrastructure.driven.mongosource

import com.example.__PKG__.domain.ports.SourceDataPort
import org.apache.spark.sql.{DataFrame, SparkSession}

/** Lee la colección del read model CQRS (MongoDB) vía mongo-spark-connector (§0, DS-CQRS-3).
 *  Nunca apunta a la BD de escritura (PostgreSQL). */
class SparkMongoSourceAdapter(
    spark: SparkSession,
    uri: String,
    database: String,
    collection: String
) extends SourceDataPort {

  override def read(): DataFrame =
    spark.read
      .format("mongodb")
      .option("connection.uri", uri)
      .option("database", database)
      .option("collection", collection)
      .load()
}
''', pkg))


def jdbc_source_adapter(root: Path, pkg: str) -> None:
    base = _scala_base(pkg, "driven")
    write(root, f"{base}/jdbcsource/SparkJdbcSourceAdapter.scala", _r('''package com.example.__PKG__.infrastructure.driven.jdbcsource

import com.example.__PKG__.domain.ports.SourceDataPort
import org.apache.spark.sql.{DataFrame, SparkSession}

/** Adaptador de origen JDBC para proyectos SIN CQRS (alternativa a Mongo). */
class SparkJdbcSourceAdapter(
    spark: SparkSession,
    url: String,
    table: String,
    user: String,
    password: String
) extends SourceDataPort {

  override def read(): DataFrame =
    spark.read
      .format("jdbc")
      .option("url", url)
      .option("dbtable", table)
      .option("user", user)
      .option("password", password)
      .load()
}
''', pkg))


def s3_parquet_adapter(root: Path, pkg: str) -> None:
    base = _scala_base(pkg, "driven")
    write(root, f"{base}/s3parquet/SparkS3ParquetAdapter.scala", _r('''package com.example.__PKG__.infrastructure.driven.s3parquet

import com.example.__PKG__.domain.ports.ParquetStorePort
import org.apache.spark.sql.{DataFrame, SaveMode, SparkSession}

/** Lee/escribe parquet en S3 (floci en dev, AWS real en prod). Layout §9.1.
 *  Idempotente por `reportId` con sobrescritura determinista (DR-3). */
class SparkS3ParquetAdapter(spark: SparkSession, bucket: String) extends ParquetStorePort {

  override def writeRaw(reportType: String, reportId: String, df: DataFrame): String = {
    val uri = s"s3a://$bucket/raw/$reportType/$reportId/"
    df.write.mode(SaveMode.Overwrite).parquet(uri)
    uri
  }

  override def readRaw(uri: String): DataFrame =
    spark.read.parquet(uri)

  override def writeProcessed(reportType: String, reportId: String, df: DataFrame): String = {
    val uri = s"s3a://$bucket/processed/$reportType/$reportId/"
    df.write.mode(SaveMode.Overwrite).parquet(uri)
    uri
  }
}
''', pkg))


def kafka_producer_adapter(root: Path, pkg: str) -> None:
    base = _scala_base(pkg, "driven")
    write(root, f"{base}/kafkaproducer/KafkaEventPublisher.scala", _r('''package com.example.__PKG__.infrastructure.driven.kafkaproducer

import com.example.__PKG__.domain.ports.EventBusPort
import org.apache.kafka.clients.producer.{KafkaProducer, ProducerRecord}

import java.util.Properties

/** Publica eventos de dominio (payload JSON) en Kafka. Implementa `EventBusPort`. */
class KafkaEventPublisher(bootstrapServers: String) extends EventBusPort with AutoCloseable {

  private val props = new Properties()
  props.put("bootstrap.servers", bootstrapServers)
  props.put("key.serializer", "org.apache.kafka.common.serialization.StringSerializer")
  props.put("value.serializer", "org.apache.kafka.common.serialization.StringSerializer")
  props.put("acks", "all")

  private val producer = new KafkaProducer[String, String](props)

  override def publish(topic: String, key: String, payload: String): Unit = {
    producer.send(new ProducerRecord[String, String](topic, key, payload)).get()
  }

  override def close(): Unit = producer.close()
}
''', pkg))


# --------------------------------------------------------------------------- #
# Entry point: kafka consumer (MS2)
# --------------------------------------------------------------------------- #
def kafka_consumer_entry_point(root: Path, pkg: str, topic_in: str) -> None:
    base = _scala_base(pkg, "entry")
    write(root, f"{base}/kafkaconsumer/ReportExtractedConsumer.scala", _r('''package com.example.__PKG__.infrastructure.entrypoints.kafkaconsumer

import com.example.__PKG__.application.usecases.ProcessReportUseCase
import com.example.__PKG__.domain.model.ReportType
import org.apache.kafka.clients.consumer.KafkaConsumer

import java.time.Duration
import java.util.{Collections, Properties, UUID}
import scala.jdk.CollectionConverters._

/** Entry-point dirigido por evento: consume `__TOPIC_IN__` (report.extracted) y dispara MS2. */
class ReportExtractedConsumer(
    bootstrapServers: String,
    topicIn: String = "__TOPIC_IN__",
    groupId: String = "report-processing-service",
    useCase: ProcessReportUseCase
) {

  @volatile private var running = true

  private def buildConsumer(): KafkaConsumer[String, String] = {
    val props = new Properties()
    props.put("bootstrap.servers", bootstrapServers)
    props.put("group.id", groupId)
    props.put("key.deserializer", "org.apache.kafka.common.serialization.StringDeserializer")
    props.put("value.deserializer", "org.apache.kafka.common.serialization.StringDeserializer")
    props.put("auto.offset.reset", "earliest")
    props.put("enable.auto.commit", "true")
    new KafkaConsumer[String, String](props)
  }

  def stop(): Unit = running = false

  def start(): Unit = {
    val consumer = buildConsumer()
    consumer.subscribe(Collections.singletonList(topicIn))
    try {
      while (running) {
        val records = consumer.poll(Duration.ofMillis(1000))
        for (record <- records.asScala) {
          handle(record.value())
        }
      }
    } finally {
      consumer.close()
    }
  }

  private def handle(json: String): Unit = {
    val reportType = field(json, "reportType").getOrElse("")
    val reportId   = field(json, "reportId").getOrElse(UUID.randomUUID().toString)
    val runId      = field(json, "runId").getOrElse(UUID.randomUUID().toString)
    val rawUri     = field(json, "rawParquetUri").getOrElse("")
    // Por defecto los 3 formatos; un proyecto puede derivarlos del catálogo.
    val formats    = List("PDF", "XLS", "CSV")
    useCase.execute(ReportType.fromString(reportType), reportId, runId, rawUri, formats)
  }

  // Extracción mínima de campos JSON (sustituible por una librería en endurecimiento).
  private def field(json: String, key: String): Option[String] = {
    val pattern = ("\\"" + key + "\\"\\\\s*:\\\\s*\\"([^\\"]*)\\"").r
    pattern.findFirstMatchIn(json).map(_.group(1))
  }
}
''', pkg, TOPIC_IN=topic_in))


# --------------------------------------------------------------------------- #
# BatchMain por rol
# --------------------------------------------------------------------------- #
def report_batch_main(root: Path, svc: str, pkg: str, report_role: str,
                      source: str, out_topic: str, in_topic: str,
                      types: list[str]) -> None:
    base = _scala_base(pkg, "entry")

    spark_builder = _r('''  private def buildSpark(): SparkSession = {
    val builder = SparkSession.builder
      .appName("__SVC__")
      .master(sys.env.getOrElse("SPARK_MASTER", "local[*]"))
    val endpoint = sys.env.getOrElse("AWS_ENDPOINT_URL", "")
    val spark = builder.getOrCreate()
    val hc = spark.sparkContext.hadoopConfiguration
    if (endpoint.nonEmpty) hc.set("fs.s3a.endpoint", endpoint)
    hc.set("fs.s3a.path.style.access", "true")
    hc.set("fs.s3a.access.key", sys.env.getOrElse("AWS_ACCESS_KEY_ID", "test"))
    hc.set("fs.s3a.secret.key", sys.env.getOrElse("AWS_SECRET_ACCESS_KEY", "test"))
    hc.set("fs.s3a.impl", "org.apache.hadoop.fs.s3a.S3AFileSystem")
    spark
  }
''', pkg, SVC=svc)

    if report_role == "extraction":
        if source == "mongo":
            source_wiring = _r('''      val source = new SparkMongoSourceAdapter(
        spark,
        sys.env.getOrElse("MONGO_URI", "mongodb://localhost:27017"),
        sys.env.getOrElse("MONGO_READ_DB", "readmodel"),
        sys.env.getOrElse("MONGO_READ_COLLECTION", "ventas")
      )
''', pkg)
            source_import = f"import com.example.{pkg}.infrastructure.driven.mongosource.SparkMongoSourceAdapter"
        else:
            source_wiring = _r('''      val source = new SparkJdbcSourceAdapter(
        spark,
        sys.env.getOrElse("JDBC_URL", "jdbc:postgresql://localhost:5432/app"),
        sys.env.getOrElse("JDBC_TABLE", "ventas"),
        sys.env.getOrElse("JDBC_USER", "app"),
        sys.env.getOrElse("JDBC_PASSWORD", "app")
      )
''', pkg)
            source_import = f"import com.example.{pkg}.infrastructure.driven.jdbcsource.SparkJdbcSourceAdapter"

        body = _r('''package com.example.__PKG__.infrastructure.entrypoints

import com.example.__PKG__.application.usecases.ValidateAndExtractUseCase
import com.example.__PKG__.domain.model.{ColumnSpec, ReportSchema, ReportType}
import com.example.__PKG__.infrastructure.driven.kafkaproducer.KafkaEventPublisher
import com.example.__PKG__.infrastructure.driven.s3parquet.SparkS3ParquetAdapter
__SOURCE_IMPORT__
import org.apache.spark.sql.SparkSession

import java.util.UUID

/** MS1 — extracción + validación de esquema. Lee el read model CQRS → valida → parquet `raw/`
 *  → publica `report.extracted` (§3, DR-1). */
object BatchMain {

  def main(args: Array[String]): Unit = {
    val argMap: Map[String, String] =
      args.grouped(2)
        .collect { case Array(k, v) if k.startsWith("--") => k.stripPrefix("--") -> v }
        .toMap

    val spark = buildSpark()
    try {
      val bucket    = sys.env.getOrElse("REPORT_BUCKET", "reports")
      val bootstrap = sys.env.getOrElse("KAFKA_BOOTSTRAP_SERVERS", "localhost:9092")

__SOURCE_WIRING__
      val store  = new SparkS3ParquetAdapter(spark, bucket)
      val events = new KafkaEventPublisher(bootstrap)
      val useCase = new ValidateAndExtractUseCase(source, store, events, "__OUT_TOPIC__")

      val reportType = ReportType.fromString(argMap.getOrElse("reportType", "ventas-mensual"))
      val reportId   = argMap.getOrElse("reportId", UUID.randomUUID().toString)
      val runId      = UUID.randomUUID().toString

      // TODO: resolver el ReportSchema vigente desde report_schema_catalog (§9.2).
      val schema = ReportSchema(
        reportType,
        version = "v1",
        columns = List(
          ColumnSpec("id", "string", nullable = false)
          // TODO: declarar las columnas reales del reporte.
        ),
        integrityRules = List.empty
      )

      try {
        useCase.execute(schema, reportId, runId)
      } finally {
        events.close()
      }
    } finally {
      spark.stop()
    }
  }

__SPARK_BUILDER__}
''', pkg, SOURCE_IMPORT=source_import, SOURCE_WIRING=source_wiring,
              OUT_TOPIC=out_topic, SPARK_BUILDER=spark_builder)

    else:  # processing
        imports = "\n".join(
            f"import com.example.{pkg}.application.usecases.transformers.{_transformer_class(t)}"
            for t in types
        )
        if types:
            registry_lines = "\n".join(
                f"      val t{i} = new {_transformer_class(t)}()" for i, t in enumerate(types)
            )
            registry_map = ", ".join(f"t{i}.reportType -> t{i}" for i in range(len(types)))
        else:
            registry_lines = "      // TODO: registrar transformers (--report-types vacío)."
            registry_map = ""

        body = _r('''package com.example.__PKG__.infrastructure.entrypoints

import com.example.__PKG__.application.usecases.{ProcessReportUseCase, ReportTransformer, ReportTransformerFactory}
import com.example.__PKG__.domain.model.ReportType
import com.example.__PKG__.infrastructure.driven.kafkaproducer.KafkaEventPublisher
import com.example.__PKG__.infrastructure.driven.s3parquet.SparkS3ParquetAdapter
import com.example.__PKG__.infrastructure.entrypoints.kafkaconsumer.ReportExtractedConsumer
__IMPORTS__
import org.apache.spark.sql.SparkSession

/** MS2 — transformación por tipo de reporte (modo triggered-by-event).
 *  Cablea la ReportTransformerFactory con los tipos registrados (DR-10) y arranca el consumer. */
object BatchMain {

  def main(args: Array[String]): Unit = {
    val spark = buildSpark()
    val bucket    = sys.env.getOrElse("REPORT_BUCKET", "reports")
    val bootstrap = sys.env.getOrElse("KAFKA_BOOTSTRAP_SERVERS", "localhost:9092")
    val topicIn   = sys.env.getOrElse("KAFKA_TOPIC_IN", "__TOPIC_IN__")

    val store  = new SparkS3ParquetAdapter(spark, bucket)
    val events = new KafkaEventPublisher(bootstrap)

__REGISTRY_LINES__
    val registry: Map[ReportType, ReportTransformer] = Map(__REGISTRY_MAP__)
    val factory = new ReportTransformerFactory(registry)
    val useCase = new ProcessReportUseCase(factory, store, events, "__OUT_TOPIC__")

    val consumer = new ReportExtractedConsumer(bootstrap, topicIn, "report-processing-service", useCase)
    sys.addShutdownHook {
      consumer.stop()
      events.close()
      spark.stop()
    }
    consumer.start()
  }

__SPARK_BUILDER__}
''', pkg, IMPORTS=imports, REGISTRY_LINES=registry_lines, REGISTRY_MAP=registry_map,
              TOPIC_IN=in_topic, OUT_TOPIC=out_topic, SPARK_BUILDER=spark_builder)

    write(root, f"{base}/BatchMain.scala", body)


# --------------------------------------------------------------------------- #
# Orquestación del modo reportería
# --------------------------------------------------------------------------- #
def scaffold_reporting(root: Path, svc: str, pkg: str, report_role: str,
                       source: str, in_topic: str, out_topic: str,
                       types: list[str]) -> None:
    report_domain_model(root, pkg)
    s3_parquet_adapter(root, pkg)
    kafka_producer_adapter(root, pkg)

    if report_role == "extraction":
        validate_extract_use_case(root, pkg, out_topic)
        if source == "mongo":
            mongo_source_adapter(root, pkg)
        else:
            jdbc_source_adapter(root, pkg)
    else:  # processing
        report_transformer_factory(root, pkg, types, out_topic)
        kafka_consumer_entry_point(root, pkg, in_topic)

    report_batch_main(root, svc, pkg, report_role, source, out_topic, in_topic, types)


# --------------------------------------------------------------------------- #
# write helper
# --------------------------------------------------------------------------- #
def write(root: Path, relative: str, content: str) -> None:
    target = root / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content)
    logger.info("  created %s", relative)


# --------------------------------------------------------------------------- #
# scaffold
# --------------------------------------------------------------------------- #
def scaffold(service_name: str, root_arg: str | None, service_name_provided: bool,
             report_role: str | None = None, source: str = "mongo",
             kafka_in: str = "report.extracted", kafka_out: str | None = None,
             report_types: str = "") -> None:
    root = Path(root_arg) if root_arg else Path(".")
    if service_name_provided:
        root = root / service_name

    logger.info("Scaffolding Scala hexagonal architecture at: %s", root.resolve())
    logger.info("Service name: %s", service_name)

    pkg = service_name.replace("-", "")

    # default de kafka_out por rol
    if kafka_out is None:
        kafka_out = "report.processed" if report_role == "processing" else "report.extracted"

    types = [t.strip() for t in report_types.split(",") if t.strip()]

    build_files(root, service_name, pkg, report_role, source)
    dotenv_files(root, report_role, source)

    if report_role is None:
        # Comportamiento original (retrocompatible): placeholders + BatchMain vacío.
        domain_model(root, pkg)
        application_use_cases(root, pkg)
        driven_adapters(root, pkg)
        entry_points(root, service_name, pkg)
    else:
        logger.info("Report role: %s | source: %s | types: %s", report_role, source, types)
        scaffold_reporting(root, service_name, pkg, report_role, source,
                           kafka_in, kafka_out, types)

    abs_root = root.resolve()
    print(f"\nDone! Project scaffolded at: {abs_root}")
    print("\n=== How to run the generated project ===")
    print("\nPrerequisites:")
    print("  - Java 17+")
    print("  - sbt 1.9.8  (https://www.scala-sbt.org/download)")
    print("  - Apache Spark 3.5.1 (bundled via entryPoints module)")
    print("\n1. Enter the project directory:")
    print(f"     cd {abs_root}")

    if report_role is None:
        print("\n2. Fill in .env with your Cloudflare R2 credentials:")
        print("     R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY")
        print("\n3. Run the batch job:")
        print('     sbt "entryPoints/run"')
    else:
        print("\n2. Fill in .env (S3/floci, Kafka y la fuente de datos):")
        if report_role == "extraction" and source == "mongo":
            print("     AWS_ENDPOINT_URL, REPORT_BUCKET, KAFKA_BOOTSTRAP_SERVERS,")
            print("     MONGO_URI, MONGO_READ_DB, MONGO_READ_COLLECTION (read model CQRS, §0)")
        elif report_role == "extraction":
            print("     AWS_ENDPOINT_URL, REPORT_BUCKET, KAFKA_BOOTSTRAP_SERVERS, JDBC_URL/JDBC_TABLE/...")
        else:
            print("     AWS_ENDPOINT_URL, REPORT_BUCKET, KAFKA_BOOTSTRAP_SERVERS")
        print(f"\n3. Ejecutar el job de reportería (rol: {report_role}):")
        if report_role == "extraction":
            print('     sbt "entryPoints/run --reportType ventas-mensual"')
            print(f"   → valida el esquema, escribe raw/ y publica '{kafka_out}'")
        else:
            print('     sbt "entryPoints/run"')
            print(f"   → consume '{kafka_in}', transforma por tipo y publica '{kafka_out}'")

    print("\n4. Override Spark master (e.g. point to a cluster):")
    print('     SPARK_MASTER=spark://host:7077 sbt "entryPoints/run"')
    print("\n5. Build a fat JAR:")
    print('     sbt "entryPoints/assembly"')
    print("     java -jar infrastructure/entry-points/target/scala-2.13/entry-points-assembly-0.1.0-SNAPSHOT.jar")
    print("\n6. Compile all modules without running:")
    print("     sbt compile")
    print("========================================")


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="scala_hexagonal_scaffold",
        description="Genera un proyecto base Scala (sbt) multimódulo con arquitectura hexagonal.",
    )
    parser.add_argument("--service-name", default="users", metavar="NAME",
                        help="Nombre del servicio (default: users)")
    parser.add_argument("--report-role", choices=["extraction", "processing"], default=None,
                        help="Activa el modo reportería (ETL Spark). Sin este flag → arquetipo genérico.")
    parser.add_argument("--source", choices=["mongo", "jdbc"], default="mongo",
                        help="Solo extraction: fuente de datos (mongo=read model CQRS [default] | jdbc).")
    parser.add_argument("--kafka-in", default="report.extracted", metavar="TOPIC",
                        help="Solo processing: topic Kafka a consumir (default: report.extracted).")
    parser.add_argument("--kafka-out", default=None, metavar="TOPIC",
                        help="Topic Kafka a publicar (default: report.extracted en extraction / report.processed en processing).")
    parser.add_argument("--report-types", default="", metavar="CSV",
                        help="Solo processing: lista CSV de tipos de reporte (un transformer + registro por tipo).")
    parser.add_argument("root", nargs="?", default=None, metavar="ROOT",
                        help="Directorio raíz donde generar el proyecto (default: .)")
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

    service_name_provided = "--service-name" in sys.argv

    try:
        scaffold(args.service_name, args.root, service_name_provided,
                 report_role=args.report_role, source=args.source,
                 kafka_in=args.kafka_in, kafka_out=args.kafka_out,
                 report_types=args.report_types)
    except OSError as e:
        logger.error("No se pudo crear el proyecto: %s", e)
        sys.exit(1)


if __name__ == "__main__":
    main()
