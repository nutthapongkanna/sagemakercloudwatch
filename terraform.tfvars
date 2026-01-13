aws_region  = "ap-southeast-1"
name_prefix = "poc-notebook"

alarm_email = "your_email@example.com"

allowed_cidrs = ["1.2.3.4/32"]

alarm_cpu_threshold  = 80
alarm_disk_threshold = 85

alarm_period_seconds     = 60
alarm_evaluation_periods = 1
