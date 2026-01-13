aws_region = "ap-southeast-1"
name_prefix = "poc-sagemaker"

notebook_instance_type = "ml.t3.medium"
notebook_volume_size   = 30

# แนะนำให้ใส่ IP ตัวเอง /32 เพื่อความปลอดภัย
allowed_cidrs = ["1.2.3.4/32"]

alarm_email = "your_email@example.com"

# ถ้าต้องการกำหนดเอง (ไม่ใส่ก็ใช้ Default VPC/Subnet)
# vpc_id    = "vpc-xxxxxxxx"
# subnet_id = "subnet-xxxxxxxx"

direct_internet_access = "Enabled"

alarm_cpu_threshold  = 80
alarm_disk_threshold = 85
alarm_period_seconds = 300
alarm_evaluation_periods = 2
