variable "aws_region" {
  type    = string
  default = "ap-southeast-1"
}

variable "name_prefix" {
  type    = string
  default = "poc-notebook"
}

variable "notebook_instance_type" {
  type    = string
  default = "ml.t3.medium"
}

variable "notebook_volume_size" {
  type    = number
  default = 30
}

variable "direct_internet_access" {
  type    = string
  default = "Enabled"
  validation {
    condition     = contains(["Enabled", "Disabled"], var.direct_internet_access)
    error_message = "direct_internet_access must be Enabled or Disabled"
  }
}

variable "allowed_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}

variable "alarm_email" {
  type = string
}

variable "alarm_cpu_threshold" {
  type    = number
  default = 80
}

variable "alarm_disk_threshold" {
  type    = number
  default = 85
}

# Alarm (state-change) settings - optional, you can keep for visibility
variable "alarm_period_seconds" {
  type    = number
  default = 60
}

variable "alarm_evaluation_periods" {
  type    = number
  default = 1
}

# Optional VPC/Subnet
variable "vpc_id" {
  type    = string
  default = ""
}

variable "subnet_id" {
  type    = string
  default = ""
}
