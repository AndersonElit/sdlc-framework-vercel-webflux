#!/usr/bin/env python3
"""Genera la capa serverless de generación de formatos del subsistema de reportería.

PLAN-reporteria-spark-etl.md §7.2: un *Lambda Kafka Consumer* consume `report.processed`
y publica a EventBridge (PutEvents, un evento por formato); una *rule* por formato enruta a
la lambda PDF/XLS/CSV correspondiente, que lee `processed/` parquet y escribe `output/<formato>/`.

El mismo Terraform aplica en dev (provider AWS apuntando a floci, :4566) y en staging/prod
(AWS real); solo cambian las variables de endpoint/credenciales.
"""

import argparse
import logging
import sys
from pathlib import Path

logger = logging.getLogger(__name__)

VALID_FORMATS = {"pdf", "xls", "csv"}

RENDER_LIBS = {
    "pdf": "reportlab",
    "xls": "openpyxl",
    "csv": "",  # stdlib
}


def write(root: Path, relative: str, content: str) -> None:
    target = root / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content)
    logger.info("  created %s", relative)


def _r(content: str, **kw: str) -> str:
    out = content
    for k, v in kw.items():
        out = out.replace(f"__{k}__", v)
    return out


# --------------------------------------------------------------------------- #
# Kafka consumer lambda
# --------------------------------------------------------------------------- #
def kafka_consumer_handler(root: Path, org: str, topic: str, formats: list[str]) -> None:
    base = "terraform/backend/modules/reporting-lambdas/kafka-consumer"
    write(root, f"{base}/handler.py", _r('''"""Lambda Kafka Consumer (DR-5).

Consume `__TOPIC__` (trigger Kafka/MSK o poller) y traduce cada evento a EventBridge
(PutEvents), emitiendo un evento `ReportFormatRequested` por cada formato solicitado.
NO genera formatos: solo enruta (DR-5).
"""
import json
import os
import base64

import boto3

EVENT_BUS = os.environ.get("EVENTBRIDGE_BUS", "__ORG__-report-bus")
SOURCE = "__ORG__.reporting"
DEFAULT_FORMATS = [__DEFAULT_FORMATS__]

_endpoint = os.environ.get("AWS_ENDPOINT_URL") or None
events = boto3.client("events", endpoint_url=_endpoint)


def _records(event):
    """Soporta el envelope de trigger MSK/Kafka (event['records']) y la invocación directa."""
    if "records" in event:
        for _topic, msgs in event["records"].items():
            for m in msgs:
                raw = m.get("value", "")
                try:
                    yield json.loads(base64.b64decode(raw).decode("utf-8"))
                except Exception:
                    yield json.loads(raw)
    else:
        yield event


def handler(event, _context=None):
    entries = []
    for msg in _records(event):
        formats = msg.get("formats") or DEFAULT_FORMATS
        for fmt in formats:
            detail = {
                "reportId": msg.get("reportId"),
                "reportType": msg.get("reportType"),
                "processedParquetUri": msg.get("processedParquetUri"),
                "format": fmt.upper(),
            }
            entries.append({
                "Source": SOURCE,
                "DetailType": "ReportFormatRequested",
                "Detail": json.dumps(detail),
                "EventBusName": EVENT_BUS,
            })
    if entries:
        events.put_events(Entries=entries)
    return {"published": len(entries)}
''', TOPIC=topic, ORG=org,
        DEFAULT_FORMATS=", ".join(f'"{f.upper()}"' for f in formats)))
    write(root, f"{base}/requirements.txt", "boto3\n")


# --------------------------------------------------------------------------- #
# Format lambdas (pdf / xls / csv)
# --------------------------------------------------------------------------- #
def _format_handler_body(fmt: str, org: str) -> str:
    common_head = '''"""Lambda de formato __FMT_UP__ (DR-6).

Disparada por una rule de EventBridge (detail.format = __FMT_UP__). Lee el parquet
`processedParquetUri` y escribe el archivo en `output/__FMT__/<reportType>/<reportId>.__EXT__`.
"""
import json
import os
import io

import boto3
import pyarrow.parquet as pq
import pyarrow.dataset as ds

REPORT_BUCKET = os.environ.get("REPORT_BUCKET", "__ORG__-reports")
_endpoint = os.environ.get("AWS_ENDPOINT_URL") or None
s3 = boto3.client("s3", endpoint_url=_endpoint)


def _read_table(uri: str):
    """Lee un parquet (prefijo S3) como tabla pyarrow vía s3fs/pyarrow dataset."""
    dataset = ds.dataset(uri, format="parquet", filesystem=_s3_filesystem())
    return dataset.to_table()


def _s3_filesystem():
    import pyarrow.fs as pafs
    return pafs.S3FileSystem(endpoint_override=_endpoint, scheme="http" if _endpoint else "https")


def _detail(event):
    return event.get("detail", event)


def _output_key(report_type: str, report_id: str) -> str:
    return f"output/__FMT__/{report_type}/{report_id}.__EXT__"
'''

    if fmt == "csv":
        render = '''

def handler(event, _context=None):
    d = _detail(event)
    report_id = d["reportId"]
    report_type = d.get("reportType", "report")
    table = _read_table(d["processedParquetUri"])

    import csv
    buf = io.StringIO()
    writer = csv.writer(buf)
    writer.writerow(table.column_names)
    for row in zip(*[col.to_pylist() for col in table.columns]):
        writer.writerow(row)

    key = _output_key(report_type, report_id)
    s3.put_object(Bucket=REPORT_BUCKET, Key=key, Body=buf.getvalue().encode("utf-8"))
    return {"output": f"s3://{REPORT_BUCKET}/{key}", "rows": table.num_rows}
'''
    elif fmt == "xls":
        render = '''

def handler(event, _context=None):
    from openpyxl import Workbook

    d = _detail(event)
    report_id = d["reportId"]
    report_type = d.get("reportType", "report")
    table = _read_table(d["processedParquetUri"])

    wb = Workbook()
    ws = wb.active
    ws.title = report_type[:31]
    ws.append(table.column_names)
    for row in zip(*[col.to_pylist() for col in table.columns]):
        ws.append(list(row))

    buf = io.BytesIO()
    wb.save(buf)
    key = _output_key(report_type, report_id)
    s3.put_object(Bucket=REPORT_BUCKET, Key=key, Body=buf.getvalue())
    return {"output": f"s3://{REPORT_BUCKET}/{key}", "rows": table.num_rows}
'''
    else:  # pdf
        render = '''

def handler(event, _context=None):
    from reportlab.lib.pagesizes import A4
    from reportlab.platypus import SimpleDocTemplate, Table, TableStyle
    from reportlab.lib import colors

    d = _detail(event)
    report_id = d["reportId"]
    report_type = d.get("reportType", "report")
    table = _read_table(d["processedParquetUri"])

    data = [table.column_names]
    for row in zip(*[col.to_pylist() for col in table.columns]):
        data.append([str(c) for c in row])

    buf = io.BytesIO()
    doc = SimpleDocTemplate(buf, pagesize=A4)
    t = Table(data)
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), colors.lightgrey),
        ("GRID", (0, 0), (-1, -1), 0.5, colors.grey),
    ]))
    doc.build([t])

    key = _output_key(report_type, report_id)
    s3.put_object(Bucket=REPORT_BUCKET, Key=key, Body=buf.getvalue())
    return {"output": f"s3://{REPORT_BUCKET}/{key}", "rows": table.num_rows}
'''

    ext = {"pdf": "pdf", "xls": "xlsx", "csv": "csv"}[fmt]
    return _r(common_head + render, FMT=fmt, FMT_UP=fmt.upper(), EXT=ext, ORG=org)


def format_lambda(root: Path, fmt: str, org: str) -> None:
    base = f"terraform/backend/modules/reporting-lambdas/{fmt}"
    write(root, f"{base}/handler.py", _format_handler_body(fmt, org))
    reqs = "boto3\npyarrow\n"
    lib = RENDER_LIBS[fmt]
    if lib:
        reqs += f"{lib}\n"
    write(root, f"{base}/requirements.txt", reqs)


# --------------------------------------------------------------------------- #
# Terraform
# --------------------------------------------------------------------------- #
def terraform(root: Path, org: str, topic: str, runtime: str, formats: list[str]) -> None:
    base = "terraform/backend/modules/reporting-lambdas"

    write(root, f"{base}/variables.tf", _r('''variable "org" {
  type    = string
  default = "__ORG__"
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

# floci en dev (http://VPS_IP:4566); vacío en staging/prod => AWS real.
# En dev, sobreescribir con: TF_VAR_aws_endpoint_url=http://<VPS_IP>:4566 terraform apply
variable "aws_endpoint_url" {
  type    = string
  default = "http://localhost:4566"
}

variable "report_bucket" {
  type    = string
  default = "__ORG__-reports"
}

variable "lambda_runtime" {
  type    = string
  default = "__RUNTIME__"
}

variable "kafka_bootstrap_servers" {
  type    = string
  default = "kafka:9092"
}

variable "kafka_topic" {
  type    = string
  default = "__TOPIC__"
}
''', ORG=org, RUNTIME=runtime, TOPIC=topic))

    write(root, f"{base}/iam.tf", '''data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "reporting_lambda" {
  name               = "${var.org}-reporting-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "reporting_lambda" {
  # Lee processed/, escribe output/ (DR-6) y publica a EventBridge (consumer).
  statement {
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.report_bucket}", "arn:aws:s3:::${var.report_bucket}/processed/*"]
  }
  statement {
    actions   = ["s3:PutObject"]
    resources = ["arn:aws:s3:::${var.report_bucket}/output/*"]
  }
  statement {
    actions   = ["events:PutEvents"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "reporting_lambda" {
  name   = "${var.org}-reporting-lambda"
  role   = aws_iam_role.reporting_lambda.id
  policy = data.aws_iam_policy_document.reporting_lambda.json
}
''')

    # Bus + consumer lambda + Kafka trigger
    write(root, f"{base}/eventbridge.tf", '''resource "aws_cloudwatch_event_bus" "report_bus" {
  name = "${var.org}-report-bus"
}

# --- Lambda Kafka Consumer: report.processed -> EventBridge PutEvents (DR-5) ---
data "archive_file" "kafka_consumer" {
  type        = "zip"
  source_dir  = "${path.module}/kafka-consumer"
  output_path = "${path.module}/build/kafka-consumer.zip"
}

resource "aws_lambda_function" "kafka_consumer" {
  function_name    = "${var.org}-report-kafka-consumer"
  role             = aws_iam_role.reporting_lambda.arn
  runtime          = var.lambda_runtime
  handler          = "handler.handler"
  filename         = data.archive_file.kafka_consumer.output_path
  source_code_hash = data.archive_file.kafka_consumer.output_base64sha256
  timeout          = 60

  environment {
    variables = {
      EVENTBRIDGE_BUS  = aws_cloudwatch_event_bus.report_bus.name
      AWS_ENDPOINT_URL = var.aws_endpoint_url
      REPORT_BUCKET    = var.report_bucket
    }
  }
}

# Trigger Kafka self-managed (floci/MSK) sobre el topic report.processed (DR-9).
resource "aws_lambda_event_source_mapping" "kafka_consumer" {
  function_name     = aws_lambda_function.kafka_consumer.arn
  topics            = [var.kafka_topic]
  starting_position = "TRIM_HORIZON"

  self_managed_event_source {
    endpoints = {
      KAFKA_BOOTSTRAP_SERVERS = var.kafka_bootstrap_servers
    }
  }
}
''')

    # Per-format lambdas + rules
    rules_tf = ""
    for fmt in formats:
        fmt_up = fmt.upper()
        rules_tf += _r('''
# ===================== Formato __FMT_UP__ =====================
data "archive_file" "__FMT__" {
  type        = "zip"
  source_dir  = "${path.module}/__FMT__"
  output_path = "${path.module}/build/__FMT__.zip"
}

resource "aws_lambda_function" "__FMT__" {
  function_name    = "${var.org}-report-__FMT__"
  role             = aws_iam_role.reporting_lambda.arn
  runtime          = var.lambda_runtime
  handler          = "handler.handler"
  filename         = data.archive_file.__FMT__.output_path
  source_code_hash = data.archive_file.__FMT__.output_base64sha256
  timeout          = 120
  memory_size      = 512

  environment {
    variables = {
      REPORT_BUCKET    = var.report_bucket
      AWS_ENDPOINT_URL = var.aws_endpoint_url
    }
  }
}

resource "aws_cloudwatch_event_rule" "__FMT__" {
  name           = "${var.org}-report-__FMT__"
  event_bus_name = aws_cloudwatch_event_bus.report_bus.name
  event_pattern = jsonencode({
    "source"      = ["${var.org}.reporting"]
    "detail-type" = ["ReportFormatRequested"]
    "detail"      = { "format" = ["__FMT_UP__"] }
  })
}

resource "aws_cloudwatch_event_target" "__FMT__" {
  rule           = aws_cloudwatch_event_rule.__FMT__.name
  event_bus_name = aws_cloudwatch_event_bus.report_bus.name
  arn            = aws_lambda_function.__FMT__.arn
}

resource "aws_lambda_permission" "__FMT__" {
  statement_id  = "AllowEventBridge__FMT_UP__"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.__FMT__.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.__FMT__.arn
}
''', FMT=fmt, FMT_UP=fmt_up)

    write(root, f"{base}/formats.tf", rules_tf.lstrip("\n"))

    write(root, f"{base}/outputs.tf", '''output "report_bus_name" {
  value = aws_cloudwatch_event_bus.report_bus.name
}

output "kafka_consumer_function" {
  value = aws_lambda_function.kafka_consumer.function_name
}
''')



# --------------------------------------------------------------------------- #
# scaffold
# --------------------------------------------------------------------------- #
def scaffold(org: str, formats: list[str], topic: str, runtime: str,
             root_arg: str | None) -> None:
    root = Path(root_arg) if root_arg else Path(".")
    logger.info("Scaffolding reporting serverless layer at: %s", root.resolve())
    logger.info("org=%s formats=%s topic=%s runtime=%s", org, formats, topic, runtime)

    kafka_consumer_handler(root, org, topic, formats)
    for fmt in formats:
        format_lambda(root, fmt, org)
    terraform(root, org, topic, runtime, formats)

    write(root, "terraform/backend/modules/reporting-lambdas/README.md", _r('''# reporting-lambdas — capa serverless de formatos

Generado por `report_lambdas_scaffold.py` (PLAN-reporteria-spark-etl.md §7.2).

```
terraform/backend/modules/reporting-lambdas/
├── variables.tf
├── iam.tf
├── eventbridge.tf
├── formats.tf
├── outputs.tf
├── kafka-consumer/   # consume __TOPIC__ -> PutEvents EventBridge (DR-5)
__FORMAT_DIRS__
```

## Desplegar (dev, floci)

Descomentar el bloque `module "reporting_lambdas"` en
`terraform/backend/environments/dev/main.tf`, luego:

```bash
cd terraform/backend/environments/dev
terraform init
terraform apply
```

El **mismo** módulo aplica en staging/prod (AWS real): solo cambian las variables
`aws_endpoint_url` (vacío => AWS real) pasadas desde cada environment (DR-8).
''', TOPIC=topic,
        FORMAT_DIRS="".join(f"├── {f}/{' ' * (16 - len(f))}# parquet -> {f.upper()} -> output/{f}/\n"
                            for f in formats)))

    abs_root = root.resolve()
    tf_module = abs_root / "terraform/backend/modules/reporting-lambdas"
    print(f"\nDone! Reporting serverless layer scaffolded at: {tf_module}")
    print("\nNext:")
    print("  1. Descomenta el bloque module \"reporting_lambdas\" en terraform/backend/environments/dev/main.tf")
    print("  2. cd terraform/backend/environments/dev && terraform init && terraform validate")
    print("  3. terraform apply   # dev sobre floci (:4566)")


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="report_lambdas_scaffold",
        description="Genera la capa serverless de formatos (lambdas + Terraform EventBridge).",
    )
    parser.add_argument("--org", required=True, help="Prefijo del proyecto (buckets/bus).")
    parser.add_argument("--formats", default="pdf,xls,csv",
                        help="Lista CSV de formatos (pdf,xls,csv). Default: pdf,xls,csv")
    parser.add_argument("--kafka-topic", default="report.processed",
                        help="Topic que consume el Lambda Kafka Consumer (default: report.processed).")
    parser.add_argument("--runtime", default="python3.12", help="Runtime de las lambdas.")
    parser.add_argument("root", nargs="?", default=None, help="Directorio raíz (default: .)")
    parser.add_argument("-v", "--verbose", action="store_true")

    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
        stream=sys.stdout,
    )

    formats = [f.strip().lower() for f in args.formats.split(",") if f.strip()]
    invalid = set(formats) - VALID_FORMATS
    if invalid:
        logger.error("Formatos no soportados: %s (válidos: pdf, xls, csv)", invalid)
        sys.exit(1)

    try:
        scaffold(args.org, formats, args.kafka_topic, args.runtime, args.root)
    except OSError as e:
        logger.error("No se pudo generar la capa serverless: %s", e)
        sys.exit(1)


if __name__ == "__main__":
    main()
