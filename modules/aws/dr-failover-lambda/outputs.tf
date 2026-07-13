output "sns_topic_arn" {
  description = "SNS topic used by the failover alarm."
  value       = local.enabled ? aws_sns_topic.failover[0].arn : null
}

output "lambda_function_name" {
  description = "Name of the failover Lambda."
  value       = local.enabled ? aws_lambda_function.failover[0].function_name : null
}

output "lambda_role_arn" {
  description = "IAM role used by the failover Lambda."
  value       = local.enabled ? aws_iam_role.lambda[0].arn : null
}
