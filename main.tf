############################################
# Identity / Random
############################################
data "aws_caller_identity" "current" {}

resource "random_id" "suffix" {
  byte_length = 4
}

############################################
# Locals
############################################
locals {
  suffix          = random_id.suffix.hex
  notebook_name   = "${var.name_prefix}-nb-${local.suffix}"
  bucket_name     = lower("${var.name_prefix}-bucket-${data.aws_caller_identity.current.account_id}-${local.suffix}")
  sns_topic_name  = "${var.name_prefix}-alerts-${local.suffix}"
  cw_alarm_prefix = "${var.name_prefix}-alarm-${local.suffix}"

  metrics_namespace = "POC/Notebook"
}

############################################
# Network (Default VPC/Subnet fallback)
############################################
data "aws_vpc" "default" {
  count   = var.vpc_id == "" ? 1 : 0
  default = true
}

locals {
  resolved_vpc_id = var.vpc_id != "" ? var.vpc_id : data.aws_vpc.default[0].id
}

data "aws_subnets" "default" {
  count = var.subnet_id == "" ? 1 : 0
  filter {
    name   = "vpc-id"
    values = [local.resolved_vpc_id]
  }
}

locals {
  resolved_subnet_id = var.subnet_id != "" ? var.subnet_id : data.aws_subnets.default[0].ids[0]
}

############################################
# S3 Bucket
############################################
resource "aws_s3_bucket" "this" {
  bucket = local.bucket_name
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

############################################
# SNS (email)
############################################
resource "aws_sns_topic" "alarms" {
  name = local.sns_topic_name
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

############################################
# IAM Role for SageMaker Notebook
############################################
data "aws_iam_policy_document" "assume_sagemaker" {
  statement {
    effect = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["sagemaker.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sagemaker" {
  name               = "${var.name_prefix}-role-${local.suffix}"
  assume_role_policy = data.aws_iam_policy_document.assume_sagemaker.json
}

data "aws_iam_policy_document" "sagemaker_inline" {
  statement {
    sid     = "S3AccessThisBucket"
    effect  = "Allow"
    actions = ["s3:ListBucket"]
    resources = [aws_s3_bucket.this.arn]
  }

  statement {
    sid     = "S3ObjectAccessThisBucket"
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.this.arn}/*"]
  }

  statement {
    sid     = "PutCustomMetrics"
    effect  = "Allow"
    actions = ["cloudwatch:PutMetricData"]
    resources = ["*"]
  }

  statement {
    sid     = "LogsBasic"
    effect  = "Allow"
    actions = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "sagemaker_inline" {
  name   = "${var.name_prefix}-inline-${local.suffix}"
  role   = aws_iam_role.sagemaker.id
  policy = data.aws_iam_policy_document.sagemaker_inline.json
}

############################################
# Security Group for Notebook
############################################
resource "aws_security_group" "notebook" {
  name   = "${var.name_prefix}-nb-sg-${local.suffix}"
  vpc_id = local.resolved_vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

############################################
# Lifecycle Config: push CPU/Disk metrics every 1 min (cron)
# IMPORTANT: Dimension NotebookInstanceName = local.notebook_name (SageMaker name)
############################################
resource "aws_sagemaker_notebook_instance_lifecycle_configuration" "metrics" {
  name = "${var.name_prefix}-lc-metrics-${local.suffix}"

  on_start = base64encode(<<-EOF
    #!/bin/bash
    set -euo pipefail

    NB_NAME='${local.notebook_name}'
    REGION='${var.aws_region}'
    NAMESPACE='${local.metrics_namespace}'

    sudo tee /usr/local/bin/push_metrics.sh >/dev/null <<'EOT'
    #!/bin/bash
    set -euo pipefail

    NB_NAME="__NB_NAME__"
    REGION="__REGION__"
    NAMESPACE="__NAMESPACE__"

    cpu_used() {
      read -r cpu u n s i io irq sirq st g gn < /proc/stat
      idle1=$((i+io)); total1=$((u+n+s+irq+sirq+st+idle1))
      sleep 1
      read -r cpu u n s i io irq sirq st g gn < /proc/stat
      idle2=$((i+io)); total2=$((u+n+s+irq+sirq+st+idle2))
      dt=$((total2-total1))
      if [ "$dt" -le 0 ]; then echo 0; return; fi
      echo $((100*((dt-(idle2-idle1)))/dt))
    }

    disk_used() {
      df -P / | awk 'NR==2 {gsub("%","",$5); print $5}'
    }

    CPU=$(cpu_used || echo 0)
    DISK=$(disk_used || echo 0)

    # ✅ IMPORTANT: use $CPU / $DISK (NOT ${CPU}) so Terraform won't interpolate
    echo "Sending NB_NAME=$NB_NAME CPU=$CPU% DISK=$DISK% REGION=$REGION" >> /var/log/push_metrics.log

    aws cloudwatch put-metric-data \
      --region "$REGION" \
      --namespace "$NAMESPACE" \
      --metric-data \
        "MetricName=CPUUsedPercent,Value=$CPU,Unit=Percent,Dimensions=[{Name=NotebookInstanceName,Value=$NB_NAME}]" \
        "MetricName=DiskUsedPercent,Value=$DISK,Unit=Percent,Dimensions=[{Name=NotebookInstanceName,Value=$NB_NAME}]"
    EOT

    sudo sed -i "s|__NB_NAME__|$NB_NAME|g" /usr/local/bin/push_metrics.sh
    sudo sed -i "s|__REGION__|$REGION|g" /usr/local/bin/push_metrics.sh
    sudo sed -i "s|__NAMESPACE__|$NAMESPACE|g" /usr/local/bin/push_metrics.sh
    sudo sed -i 's/\\r$//' /usr/local/bin/push_metrics.sh

    sudo chmod +x /usr/local/bin/push_metrics.sh

    echo "* * * * * root /usr/local/bin/push_metrics.sh >> /var/log/push_metrics.log 2>&1" | sudo tee /etc/cron.d/push_metrics >/dev/null
    sudo chmod 0644 /etc/cron.d/push_metrics
    sudo service crond restart || sudo systemctl restart crond || true
  EOF
  )
}

############################################
# SageMaker Notebook Instance
############################################
resource "aws_sagemaker_notebook_instance" "this" {
  name                   = local.notebook_name
  role_arn               = aws_iam_role.sagemaker.arn
  instance_type          = var.notebook_instance_type
  subnet_id              = local.resolved_subnet_id
  security_groups        = [aws_security_group.notebook.id]
  volume_size            = var.notebook_volume_size
  direct_internet_access = var.direct_internet_access

  lifecycle_config_name  = aws_sagemaker_notebook_instance_lifecycle_configuration.metrics.name

  tags = { Name = local.notebook_name }
}

############################################
# CloudWatch Alarms (state-change notifications)
############################################
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${local.cw_alarm_prefix}-cpu-high"
  alarm_description   = "CPUUsedPercent high on ${local.notebook_name}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = var.alarm_evaluation_periods
  period              = var.alarm_period_seconds
  statistic           = "Average"
  threshold           = var.alarm_cpu_threshold
  treat_missing_data  = "missing"

  namespace   = local.metrics_namespace
  metric_name = "CPUUsedPercent"

  dimensions = {
    NotebookInstanceName = aws_sagemaker_notebook_instance.this.name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "disk_high" {
  alarm_name          = "${local.cw_alarm_prefix}-disk-high"
  alarm_description   = "DiskUsedPercent high on ${local.notebook_name}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = var.alarm_evaluation_periods
  period              = var.alarm_period_seconds
  statistic           = "Average"
  threshold           = var.alarm_disk_threshold
  treat_missing_data  = "missing"

  namespace   = local.metrics_namespace
  metric_name = "DiskUsedPercent"

  dimensions = {
    NotebookInstanceName = aws_sagemaker_notebook_instance.this.name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

############################################
# Lambda + EventBridge: repeat email every 5 minutes while breached
############################################
locals {
  notifier_lambda_py = <<-PY
import os, json
from datetime import datetime, timezone, timedelta
import boto3

cw  = boto3.client("cloudwatch")
sns = boto3.client("sns")

SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
NOTEBOOK_NAME = os.environ["NOTEBOOK_NAME"]
NAMESPACE     = os.environ["NAMESPACE"]

CPU_METRIC    = os.environ.get("CPU_METRIC", "CPUUsedPercent")
DISK_METRIC   = os.environ.get("DISK_METRIC", "DiskUsedPercent")
CPU_THRESH    = float(os.environ.get("CPU_THRESHOLD", "80"))
DISK_THRESH   = float(os.environ.get("DISK_THRESHOLD", "85"))
WINDOW_MIN    = int(os.environ.get("WINDOW_MINUTES", "10"))

def latest_avg(metric_name: str):
    end = datetime.now(timezone.utc)
    start = end - timedelta(minutes=WINDOW_MIN)
    resp = cw.get_metric_statistics(
        Namespace=NAMESPACE,
        MetricName=metric_name,
        Dimensions=[{"Name": "NotebookInstanceName", "Value": NOTEBOOK_NAME}],
        StartTime=start,
        EndTime=end,
        Period=60,
        Statistics=["Average"],
    )
    dps = resp.get("Datapoints", [])
    if not dps:
        return None
    dps.sort(key=lambda x: x["Timestamp"])
    return float(dps[-1]["Average"])

def handler(event, context):
    cpu = latest_avg(CPU_METRIC)
    disk = latest_avg(DISK_METRIC)

    if cpu is None and disk is None:
        return {"ok": True, "note": "no datapoints"}

    breaches = []
    if cpu is not None and cpu >= CPU_THRESH:
        breaches.append(f"CPU {cpu:.1f}% >= {CPU_THRESH:.1f}%")
    if disk is not None and disk >= DISK_THRESH:
        breaches.append(f"Disk {disk:.1f}% >= {DISK_THRESH:.1f}%")

    if not breaches:
        return {"ok": True, "breach": False, "cpu": cpu, "disk": disk}

    payload = {
        "time_utc": datetime.now(timezone.utc).isoformat(),
        "notebook": NOTEBOOK_NAME,
        "namespace": NAMESPACE,
        "cpu_avg": cpu,
        "disk_avg": disk,
        "thresholds": {"cpu": CPU_THRESH, "disk": DISK_THRESH},
        "breaches": breaches,
        "repeat": "This email repeats every 5 minutes while still breached."
    }

    subject = f"[ALERT] {NOTEBOOK_NAME} still breached"
    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject=subject[:100],
        Message=json.dumps(payload, indent=2),
    )
    return {"ok": True, "breach": True, "breaches": breaches, "cpu": cpu, "disk": disk}
PY
}

resource "local_file" "lambda_py" {
  filename = "${path.module}/lambda/notifier.py"
  content  = local.notifier_lambda_py
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = local_file.lambda_py.filename
  output_path = "${path.module}/lambda/notifier.zip"
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.name_prefix}-lambda-role-${local.suffix}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "lambda_policy" {
  statement {
    effect = "Allow"
    actions = [
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:GetMetricData"
    ]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alarms.arn]
  }

  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "${var.name_prefix}-lambda-policy-${local.suffix}"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_policy.json
}

resource "aws_lambda_function" "notifier" {
  function_name = "${var.name_prefix}-notifier-${local.suffix}"
  role          = aws_iam_role.lambda.arn
  handler       = "notifier.handler"
  runtime       = "python3.12"

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  timeout = 30

  environment {
    variables = {
      SNS_TOPIC_ARN  = aws_sns_topic.alarms.arn
      NOTEBOOK_NAME  = aws_sagemaker_notebook_instance.this.name
      NAMESPACE      = local.metrics_namespace

      CPU_METRIC     = "CPUUsedPercent"
      DISK_METRIC    = "DiskUsedPercent"
      CPU_THRESHOLD  = tostring(var.alarm_cpu_threshold)
      DISK_THRESHOLD = tostring(var.alarm_disk_threshold)

      WINDOW_MINUTES = "10"
    }
  }
}

resource "aws_cloudwatch_event_rule" "every_5_min" {
  name                = "${var.name_prefix}-every-5min-${local.suffix}"
  schedule_expression = "rate(5 minutes)"
}

resource "aws_cloudwatch_event_target" "invoke_lambda" {
  rule      = aws_cloudwatch_event_rule.every_5_min.name
  target_id = "invoke-notifier"
  arn       = aws_lambda_function.notifier.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.notifier.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.every_5_min.arn
}
