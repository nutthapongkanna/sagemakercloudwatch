output "notebook_name" {
  value = aws_sagemaker_notebook_instance.this.name
}

output "notebook_arn" {
  value = aws_sagemaker_notebook_instance.this.arn
}

output "notebook_url" {
  value = aws_sagemaker_notebook_instance.this.url
}

output "s3_bucket_name" {
  value = aws_s3_bucket.this.bucket
}

output "sns_topic_arn" {
  value = aws_sns_topic.alarms.arn
}

output "security_group_id" {
  value = aws_security_group.notebook.id
}

output "subnet_id" {
  value = local.resolved_subnet_id
}

output "vpc_id" {
  value = local.resolved_vpc_id
}

output "event_rule_name" {
  value = aws_cloudwatch_event_rule.every_5_min.name
}

output "lambda_function_name" {
  value = aws_lambda_function.notifier.function_name
}
