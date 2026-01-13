data "aws_caller_identity" "current" {}

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  suffix          = random_id.suffix.hex
  notebook_name   = "${var.name_prefix}-nb-${local.suffix}"
  bucket_name     = lower(replace("${var.name_prefix}-s3-${data.aws_caller_identity.current.account_id}-${var.aws_region}-${local.suffix}", "_", "-"))
  sns_topic_name  = "${var.name_prefix}-alerts-${local.suffix}"
  cw_alarm_prefix = "${var.name_prefix}-alarm-${local.suffix}"
}

# -------------------------
# Network: Default VPC/Subnet fallback
# -------------------------
data "aws_vpc" "default" {
  count   = var.vpc_id == "" ? 1 : 0
  default = true
}

locals {
  resolved_vpc_id = var.vpc_id != "" ? var.vpc_id : data.aws_vpc.default[0].id
}

# หา default subnet ใน VPC (ถ้าไม่ได้ระบุ subnet_id)
data "aws_subnets" "default_for_az" {
  count = var.subnet_id == "" ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [local.resolved_vpc_id]
  }

  # ค่า tag/flag นี้มีใน default subnet โดยทั่วไป
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

locals {
  resolved_subnet_id = var.subnet_id != "" ? var.subnet_id : element(data.aws_subnets.default_for_az[0].ids, 0)
}

# -------------------------
# S3 Bucket (data/artifacts)
# -------------------------
resource "aws_s3_bucket" "notebook" {
  bucket        = local.bucket_name
  force_destroy = false
}

resource "aws_s3_bucket_versioning" "notebook" {
  bucket = aws_s3_bucket.notebook.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "notebook" {
  bucket                  = aws_s3_bucket.notebook.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# -------------------------
# IAM Role for SageMaker Notebook
# -------------------------
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
  name               = "${var.name_prefix}-sm-role-${local.suffix}"
  assume_role_policy = data.aws_iam_policy_document.assume_sagemaker.json
}

# Least-privilege S3 policy for this bucket only (+ CloudWatch Logs basic)
data "aws_iam_policy_document" "sagemaker_inline" {
  statement {
    sid     = "S3BucketAccess"
    effect  = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation"
    ]
    resources = [aws_s3_bucket.notebook.arn]
  }

  statement {
    sid     = "S3ObjectAccess"
    effect  = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject"
    ]
    resources = ["${aws_s3_bucket.notebook.arn}/*"]
  }

  statement {
    sid    = "CloudWatchLogsBasic"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "sagemaker_inline" {
  name   = "${var.name_prefix}-sm-inline-${local.suffix}"
  role   = aws_iam_role.sagemaker.id
  policy = data.aws_iam_policy_document.sagemaker_inline.json
}

# -------------------------
# Security Group for Notebook (HTTPS 443)
# -------------------------
resource "aws_security_group" "notebook" {
  name        = "${var.name_prefix}-nb-sg-${local.suffix}"
  description = "Allow HTTPS (443) to SageMaker Notebook"
  vpc_id      = local.resolved_vpc_id

  ingress {
    description = "HTTPS to Notebook"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidrs
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# -------------------------
# SageMaker Notebook Instance
# -------------------------
resource "aws_sagemaker_notebook_instance" "this" {
  name                  = local.notebook_name
  role_arn              = aws_iam_role.sagemaker.arn
  instance_type         = var.notebook_instance_type
  subnet_id             = local.resolved_subnet_id
  security_groups       = [aws_security_group.notebook.id]
  volume_size           = var.notebook_volume_size
  direct_internet_access = var.direct_internet_access

  tags = {
    Name = local.notebook_name
  }
}

# -------------------------
# SNS Topic + Email subscription
# -------------------------
resource "aws_sns_topic" "alarms" {
  name = local.sns_topic_name
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# -------------------------
# CloudWatch Alarms for Notebook
# Namespace: AWS/SageMaker
# Dimensions: NotebookInstanceName
# -------------------------
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${local.cw_alarm_prefix}-cpu-high"
  alarm_description   = "CPUUtilization high on ${local.notebook_name}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = var.alarm_evaluation_periods
  period              = var.alarm_period_seconds
  statistic           = "Average"
  threshold           = var.alarm_cpu_threshold
  treat_missing_data  = "missing"

  namespace   = "AWS/SageMaker"
  metric_name = "CPUUtilization"

  dimensions = {
    NotebookInstanceName = aws_sagemaker_notebook_instance.this.name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "disk_high" {
  alarm_name          = "${local.cw_alarm_prefix}-disk-high"
  alarm_description   = "DiskUtilization high on ${local.notebook_name}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = var.alarm_evaluation_periods
  period              = var.alarm_period_seconds
  statistic           = "Average"
  threshold           = var.alarm_disk_threshold
  treat_missing_data  = "missing"

  namespace   = "AWS/SageMaker"
  metric_name = "DiskUtilization"

  dimensions = {
    NotebookInstanceName = aws_sagemaker_notebook_instance.this.name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}
