aws_region   = "ap-southeast-1"
name_prefix  = "sagemakercloudwatch"
alarm_email  = "your-email@example.com"

# network (optional)
vpc_id    = ""
subnet_id = ""
allowed_cidrs = ["0.0.0.0/0"]

# notebook
notebook_instance_type   = "ml.t3.medium"
notebook_volume_size     = 150
direct_internet_access   = "Enabled"

# metrics
metrics_namespace = "POC/Notebook"
cpu_metric_name   = "CPUUsedPercent"
disk_metric_name  = "DiskUsedPercent"
metrics_cron      = "* * * * *"
metrics_log_path  = "/var/log/push_metrics.log"

# alarms
alarm_period_seconds     = 60
alarm_evaluation_periods = 1
alarm_cpu_threshold      = 20
alarm_disk_threshold     = 20
alarm_treat_missing_data = "missing"

# repeat notifier
repeat_enabled       = true
repeat_rate_minutes  = 5
repeat_window_minutes = 10
lambda_runtime       = "python3.12"
lambda_timeout_seconds = 30
