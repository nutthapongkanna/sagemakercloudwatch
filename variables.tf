variable "aws_region" {
  type        = string
  description = "AWS region"
}

variable "name_prefix" {
  type        = string
  description = "Prefix for all resource names"
}

variable "alarm_email" {
  type        = string
  description = "Email for SNS subscription (must confirm)"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID (empty = use default VPC)"
  default     = ""
}

variable "subnet_id" {
  type        = string
  description = "Subnet ID (empty = use first subnet in selected VPC)"
  default     = ""
}

variable "allowed_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to access notebook (443)"
  default     = ["0.0.0.0/0"]
}

# =========================
# SageMaker Notebook
# =========================
variable "notebook_instance_type" {
  type        = string
  description = "SageMaker notebook instance type"
  default     = "ml.t3.medium"
}

variable "notebook_volume_size" {
  type        = number
  description = "Notebook EBS volume size (GB)"
  default     = 150
}

variable "direct_internet_access" {
  type        = string
  description = "Enabled or Disabled"
  default     = "Enabled"
  validation {
    condition     = contains(["Enabled", "Disabled"], var.direct_internet_access)
    error_message = "direct_internet_access must be Enabled or Disabled"
  }
}

# =========================
# Custom Metrics (push script)
# =========================
variable "metrics_namespace" {
  type        = string
  description = "CloudWatch namespace for custom metrics"
  default     = "POC/Notebook"
}

variable "cpu_metric_name" {
  type        = string
  description = "Custom metric name for CPU"
  default     = "CPUUsedPercent"
}

variable "disk_metric_name" {
  type        = string
  description = "Custom metric name for Disk"
  default     = "DiskUsedPercent"
}

variable "metrics_cron" {
  type        = string
  description = "Cron expression for pushing metrics on the notebook (cron.d format)"
  default     = "* * * * *"
}

variable "metrics_log_path" {
  type        = string
  description = "Path to metrics push log on notebook instance"
  default     = "/var/log/push_metrics.log"
}

# =========================
# CloudWatch Alarm settings
# =========================
variable "alarm_period_seconds" {
  type        = number
  description = "Alarm period in seconds"
  default     = 60
}

variable "alarm_evaluation_periods" {
  type        = number
  description = "Evaluation periods"
  default     = 1
}

variable "alarm_cpu_threshold" {
  type        = number
  description = "CPU threshold percent"
  default     = 80
}

variable "alarm_disk_threshold" {
  type        = number
  description = "Disk threshold percent"
  default     = 85
}

variable "alarm_treat_missing_data" {
  type        = string
  description = "missing | breaching | notBreaching | ignore"
  default     = "missing"
}

# =========================
# Repeat notifier (Lambda + EventBridge)
# =========================
variable "repeat_enabled" {
  type        = bool
  description = "Enable repeat notifications via Lambda + EventBridge"
  default     = true
}

variable "repeat_rate_minutes" {
  type        = number
  description = "EventBridge schedule rate (minutes)"
  default     = 5
}

variable "repeat_window_minutes" {
  type        = number
  description = "How far back to look for latest datapoints"
  default     = 10
}

variable "lambda_runtime" {
  type        = string
  description = "Lambda runtime"
  default     = "python3.12"
}

variable "lambda_timeout_seconds" {
  type        = number
  description = "Lambda timeout"
  default     = 30
}

variable "alarm_mem_threshold" {
  type        = number
  description = "Threshold for MemoryUsedPercent"
  default     = 80
}
