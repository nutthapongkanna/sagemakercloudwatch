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
  bucket_name     = lower("${var.name_prefix}-bucket-${data.aws_caller_identity.current.account_id}-${local.suffix}")
  sns_topic_name  = "${var.name_prefix}-alerts-${local.suffix}"
  cw_alarm_prefix = "${var.name_prefix}-alarm-${local.suffix}"

  studio_domain_name = "${var.name_prefix}-studio-${local.suffix}"
  user_profile_name  = "${var.name_prefix}-user-${local.suffix}"

  # Custom metrics namespace
  metrics_namespace = "POC/Studio"
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
  count = length(var.subnet_ids) == 0 ? 1 : 0
  filter {
    name   = "vpc-id"
    values = [local.resolved_vpc_id]
  }
}

locals {
  # ✅ one-line ternary (กันพัง)
  resolved_subnet_ids = length(var.subnet_ids) > 0 ? var.subnet_ids : data.aws_subnets.default[0].ids
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
# IAM Role for SageMaker Studio (Execution Role)
############################################
data "aws_iam_policy_document" "assume_sagemaker" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["sagemaker.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sagemaker" {
  name               = "${var.name_prefix}-studio-role-${local.suffix}"
  assume_role_policy = data.aws_iam_policy_document.assume_sagemaker.json
}

# ============================================================
# ✅ POC MAX Permissions (แก้ปัญหา CreateSpace/AddTags/PresignedUrl ฯลฯ)
# ============================================================
resource "aws_iam_role_policy" "sagemaker_poc_max" {
  name = "${var.name_prefix}-studio-pocmax-${local.suffix}"
  role = aws_iam_role.sagemaker.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = "sagemaker:*",
        Resource = "*"
      },
      {
        # Studio/Space มักต้อง PassRole
        Effect   = "Allow",
        Action   = "iam:PassRole",
        Resource = "*"
      },
      {
        # Monitoring / Logs / Infra ที่เกี่ยวข้อง
        Effect = "Allow",
        Action = [
          "cloudwatch:*",
          "logs:*",
          "ec2:*",
          "efs:*",
          "s3:*"
        ],
        Resource = "*"
      }
    ]
  })
}

############################################
# Security Group for Studio Apps
############################################
resource "aws_security_group" "studio" {
  name   = "${var.name_prefix}-studio-sg-${local.suffix}"
  vpc_id = local.resolved_vpc_id

  # allow internal traffic within the SG (common for EFS/app comms)
  ingress {
    description = "self"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

############################################
# Studio Lifecycle Config (JupyterServer)
# Push CPU/Disk/Memory metrics every 1 min (cron)
# Dimension: UserProfileName = local.user_profile_name
############################################
resource "aws_sagemaker_studio_lifecycle_config" "metrics" {
  studio_lifecycle_config_name     = "${var.name_prefix}-lc-metrics-${local.suffix}"
  studio_lifecycle_config_app_type = "JupyterServer"

  studio_lifecycle_config_content = base64encode(<<-EOF
    #!/bin/bash
    set -euo pipefail

    USER_PROFILE='${local.user_profile_name}'
    REGION='${var.aws_region}'
    NAMESPACE='${local.metrics_namespace}'

    sudo tee /usr/local/bin/push_metrics.sh >/dev/null <<'EOT'
    #!/bin/bash
    set -euo pipefail

    USER_PROFILE="__USER_PROFILE__"
    REGION="__REGION__"
    NAMESPACE="__NAMESPACE__"

    AWS_BIN="$(command -v aws || true)"

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

    mem_used() {
      awk '
        /MemTotal/ {t=$2}
        /MemAvailable/ {a=$2}
        END {
          if (t<=0) {print 0; exit}
          print int(100*(t-a)/t)
        }' /proc/meminfo
    }

    CPU=$(cpu_used || echo 0)
    DISK=$(disk_used || echo 0)
    MEM=$(mem_used || echo 0)

    echo "$(date -Is) Sending USER_PROFILE=$USER_PROFILE CPU=$CPU% DISK=$DISK% MEM=$MEM% REGION=$REGION AWS_BIN=$AWS_BIN" >> /var/log/push_metrics.log

    "$AWS_BIN" cloudwatch put-metric-data \
      --region "$REGION" \
      --namespace "$NAMESPACE" \
      --metric-data \
        "MetricName=CPUUsedPercent,Value=$CPU,Unit=Percent,Dimensions=[{Name=UserProfileName,Value=$USER_PROFILE}]" \
        "MetricName=DiskUsedPercent,Value=$DISK,Unit=Percent,Dimensions=[{Name=UserProfileName,Value=$USER_PROFILE}]" \
        "MetricName=MemoryUsedPercent,Value=$MEM,Unit=Percent,Dimensions=[{Name=UserProfileName,Value=$USER_PROFILE}]"
    EOT

    sudo sed -i "s|__USER_PROFILE__|$USER_PROFILE|g" /usr/local/bin/push_metrics.sh
    sudo sed -i "s|__REGION__|$REGION|g" /usr/local/bin/push_metrics.sh
    sudo sed -i "s|__NAMESPACE__|$NAMESPACE|g" /usr/local/bin/push_metrics.sh
    sudo sed -i 's/\\r$//' /usr/local/bin/push_metrics.sh
    sudo chmod +x /usr/local/bin/push_metrics.sh

    echo "* * * * * root /usr/local/bin/push_metrics.sh >> /var/log/push_metrics.log 2>&1" | sudo tee /etc/cron.d/push_metrics >/dev/null
    sudo chmod 0644 /etc/cron.d/push_metrics

    sudo systemctl restart cron 2>/dev/null || sudo systemctl restart crond 2>/dev/null || sudo service cron restart 2>/dev/null || sudo service crond restart 2>/dev/null || true
  EOF
  )
}

############################################
# SageMaker Studio Domain + User Profile
############################################
resource "aws_sagemaker_domain" "this" {
  domain_name = local.studio_domain_name
  auth_mode   = "IAM"
  vpc_id      = local.resolved_vpc_id

  # Studio มักใช้ 2 subnets คนละ AZ
  subnet_ids = slice(local.resolved_subnet_ids, 0, min(length(local.resolved_subnet_ids), 2))

  # PublicInternetOnly: ง่ายสุด
  # VpcOnly: private ต้องทำ VPC endpoints เพิ่มถึงจะลื่น
  app_network_access_type = var.studio_app_network_access_type

  default_user_settings {
    execution_role  = aws_iam_role.sagemaker.arn
    security_groups = [aws_security_group.studio.id]

    jupyter_server_app_settings {
      lifecycle_config_arns = [aws_sagemaker_studio_lifecycle_config.metrics.arn]
    }
  }

  # ✅ เพิ่มตามที่คุณขอ: default_space_settings
  default_space_settings {
    execution_role  = aws_iam_role.sagemaker.arn
    security_groups = [aws_security_group.studio.id]
  }

  tags = { Name = local.studio_domain_name }
}

resource "aws_sagemaker_user_profile" "this" {
  domain_id         = aws_sagemaker_domain.this.id
  user_profile_name = local.user_profile_name
  tags              = { Name = local.user_profile_name }
}

############################################
# CloudWatch Alarms (state-change notifications)
############################################
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${local.cw_alarm_prefix}-cpu-high"
  alarm_description   = "CPUUsedPercent high on Studio user ${local.user_profile_name}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = var.alarm_evaluation_periods
  period              = var.alarm_period_seconds
  statistic           = "Average"
  threshold           = var.alarm_cpu_threshold
  treat_missing_data  = "missing"

  namespace   = local.metrics_namespace
  metric_name = "CPUUsedPercent"

  dimensions = {
    UserProfileName = aws_sagemaker_user_profile.this.user_profile_name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "disk_high" {
  alarm_name          = "${local.cw_alarm_prefix}-disk-high"
  alarm_description   = "DiskUsedPercent high on Studio user ${local.user_profile_name}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = var.alarm_evaluation_periods
  period              = var.alarm_period_seconds
  statistic           = "Average"
  threshold           = var.alarm_disk_threshold
  treat_missing_data  = "missing"

  namespace   = local.metrics_namespace
  metric_name = "DiskUsedPercent"

  dimensions = {
    UserProfileName = aws_sagemaker_user_profile.this.user_profile_name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "memory_high" {
  alarm_name          = "${local.cw_alarm_prefix}-memory-high"
  alarm_description   = "MemoryUsedPercent high on Studio user ${local.user_profile_name}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = var.alarm_evaluation_periods
  period              = var.alarm_period_seconds
  statistic           = "Average"
  threshold           = var.alarm_mem_threshold
  treat_missing_data  = "missing"

  namespace   = local.metrics_namespace
  metric_name = "MemoryUsedPercent"

  dimensions = {
    UserProfileName = aws_sagemaker_user_profile.this.user_profile_name
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

SNS_TOPIC_ARN    = os.environ["SNS_TOPIC_ARN"]
NAMESPACE        = os.environ["NAMESPACE"]
DIM_NAME         = os.environ.get("DIM_NAME", "UserProfileName")
DIM_VALUE        = os.environ["DIM_VALUE"]

CPU_METRIC    = os.environ.get("CPU_METRIC", "CPUUsedPercent")
DISK_METRIC   = os.environ.get("DISK_METRIC", "DiskUsedPercent")
MEM_METRIC    = os.environ.get("MEM_METRIC", "MemoryUsedPercent")

CPU_THRESH    = float(os.environ.get("CPU_THRESHOLD", "80"))
DISK_THRESH   = float(os.environ.get("DISK_THRESHOLD", "85"))
MEM_THRESH    = float(os.environ.get("MEM_THRESHOLD", "80"))

WINDOW_MIN    = int(os.environ.get("WINDOW_MINUTES", "10"))

def latest_avg(metric_name: str):
    end = datetime.now(timezone.utc)
    start = end - timedelta(minutes=WINDOW_MIN)
    resp = cw.get_metric_statistics(
        Namespace=NAMESPACE,
        MetricName=metric_name,
        Dimensions=[{"Name": DIM_NAME, "Value": DIM_VALUE}],
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
    cpu  = latest_avg(CPU_METRIC)
    disk = latest_avg(DISK_METRIC)
    mem  = latest_avg(MEM_METRIC)

    if cpu is None and disk is None and mem is None:
        return {"ok": True, "note": "no datapoints"}

    breaches = []
    if cpu is not None and cpu >= CPU_THRESH:
        breaches.append(f"CPU {cpu:.1f}% >= {CPU_THRESH:.1f}%")
    if disk is not None and disk >= DISK_THRESH:
        breaches.append(f"Disk {disk:.1f}% >= {DISK_THRESH:.1f}%")
    if mem is not None and mem >= MEM_THRESH:
        breaches.append(f"Memory {mem:.1f}% >= {MEM_THRESH:.1f}%")

    if not breaches:
        return {"ok": True, "breach": False, "cpu": cpu, "disk": disk, "mem": mem}

    payload = {
        "time_utc": datetime.now(timezone.utc).isoformat(),
        "namespace": NAMESPACE,
        "dimension": {DIM_NAME: DIM_VALUE},
        "cpu_avg": cpu,
        "disk_avg": disk,
        "mem_avg": mem,
        "thresholds": {"cpu": CPU_THRESH, "disk": DISK_THRESH, "mem": MEM_THRESH},
        "breaches": breaches,
        "repeat": "This email repeats every 5 minutes while still breached."
    }

    subject = f"[ALERT] Studio {DIM_VALUE} still breached"
    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject=subject[:100],
        Message=json.dumps(payload, indent=2),
    )
    return {"ok": True, "breach": True, "breaches": breaches, "cpu": cpu, "disk": disk, "mem": mem}
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
    effect  = "Allow"
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
      NAMESPACE      = local.metrics_namespace

      DIM_NAME       = "UserProfileName"
      DIM_VALUE      = aws_sagemaker_user_profile.this.user_profile_name

      CPU_METRIC     = "CPUUsedPercent"
      DISK_METRIC    = "DiskUsedPercent"
      MEM_METRIC     = "MemoryUsedPercent"

      CPU_THRESHOLD  = tostring(var.alarm_cpu_threshold)
      DISK_THRESHOLD = tostring(var.alarm_disk_threshold)
      MEM_THRESHOLD  = tostring(var.alarm_mem_threshold)

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
