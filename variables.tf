variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-1"
}

variable "name_prefix" {
  description = "Prefix for all resources"
  type        = string
  default     = "demo-sagemaker"
}

variable "notebook_instance_type" {
  description = "SageMaker Notebook instance type"
  type        = string
  default     = "ml.t3.medium"
}

variable "notebook_volume_size" {
  description = "EBS volume size (GB) for notebook"
  type        = number
  default     = 20
}

variable "direct_internet_access" {
  description = "Enabled or Disabled for notebook direct internet"
  type        = string
  default     = "Enabled"
  validation {
    condition     = contains(["Enabled", "Disabled"], var.direct_internet_access)
    error_message = "direct_internet_access must be Enabled or Disabled"
  }
}

variable "vpc_id" {
  description = "Optional VPC ID. Leave empty to use Default VPC."
  type        = string
  default     = ""
}

variable "subnet_id" {
  description = "Optional Subnet ID. Leave empty to auto-pick a default subnet in the VPC."
  type        = string
  default     = ""
}

variable "allowed_cidrs" {
  description = "CIDRs allowed to access the notebook (HTTPS 443). For safety, set to your public IP /32."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "alarm_email" {
  description = "Email for SNS alarm subscription (must confirm via email)."
  type        = string
}

# --- CloudWatch Alarm thresholds ---
variable "alarm_cpu_threshold" {
  description = "CPUUtilization threshold (%)"
  type        = number
  default     = 80
}

variable "alarm_disk_threshold" {
  description = "DiskUtilization threshold (%)"
  type        = number
  default     = 85
}

variable "alarm_period_seconds" {
  description = "Alarm period in seconds"
  type        = number
  default     = 300
}

variable "alarm_evaluation_periods" {
  description = "How many periods to evaluate"
  type        = number
  default     = 2
}
