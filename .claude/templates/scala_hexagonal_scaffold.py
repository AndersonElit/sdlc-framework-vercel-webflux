#!/usr/bin/env python3
"""Genera un proyecto base Scala (sbt) multimódulo con arquitectura hexagonal y batch Spark."""

import argparse
import logging
import sys
from pathlib import Path

logger = logging.getLogger(__name__)


def build_files(root: Path, svc: str, pkg: str) -> None:
    write(root, "project/build.properties", "sbt.version=1.9.8\n")

    write(root, "project/plugins.sbt",
          'addSbtPlugin("com.eed3si9n" % "sbt-assembly" % "2.1.4")\n')

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
          "    libraryDependencies ++= catsEffect ++ spark ++ hadoop\n"
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
          "    ) ++ logging,\n"
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
          f'    assembly / mainClass := Some("com.example.{pkg}.infrastructure.entrypoints.BatchMain")\n'
          "  )\n"
          "  .dependsOn(useCases, drivenAdapters)\n"
          "\n"
          "lazy val root = project\n"
          '  .in(file("."))\n'
          "  .aggregate(domain, useCases, drivenAdapters, entryPoints)\n"
          '  .settings(name := "scala-hexagonal-architecture", publish / skip := true)\n')


def dotenv_files(root: Path) -> None:
    content = (
        "R2_ACCOUNT_ID=\n"
        "R2_ACCESS_KEY_ID=\n"
        "R2_SECRET_ACCESS_KEY=\n"
    )
    write(root, ".env", content)
    write(root, ".env.example", content)


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
          "\n"
          "  private def fatal(msg: String): Nothing = {\n"
          f'    System.err.println(s"[{svc}] ERROR: $msg")\n'
          "    sys.exit(1)\n"
          "  }\n"
          "}\n")


def write(root: Path, relative: str, content: str) -> None:
    target = root / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content)
    logger.info("  created %s", relative)


def scaffold(service_name: str, root_arg: str | None, service_name_provided: bool) -> None:
    root = Path(root_arg) if root_arg else Path(".")
    if service_name_provided:
        root = root / service_name

    logger.info("Scaffolding Scala hexagonal architecture at: %s", root.resolve())
    logger.info("Service name: %s", service_name)

    pkg = service_name.replace("-", "")

    build_files(root, service_name, pkg)
    dotenv_files(root)
    domain_model(root, pkg)
    application_use_cases(root, pkg)
    driven_adapters(root, pkg)
    entry_points(root, service_name, pkg)

    abs_root = root.resolve()
    print(f"\nDone! Project scaffolded at: {abs_root}")
    print("\n=== How to run the generated project ===")
    print("\nPrerequisites:")
    print("  - Java 17+")
    print("  - sbt 1.9.8  (https://www.scala-sbt.org/download)")
    print("  - Apache Spark 3.5.1 (bundled via entryPoints module)")
    print("\n1. Enter the project directory:")
    print(f"     cd {abs_root}")
    print("\n2. Fill in .env with your Cloudflare R2 credentials:")
    print("     R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY")
    print("\n3. Run the batch job:")
    print('     sbt "entryPoints/run"')
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
        scaffold(args.service_name, args.root, service_name_provided)
    except OSError as e:
        logger.error("No se pudo crear el proyecto: %s", e)
        sys.exit(1)


if __name__ == "__main__":
    main()
