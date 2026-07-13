locals {
  enabled = var.enabled && trimspace(var.primary_health_check_id != null ? var.primary_health_check_id : "") != ""

  name_prefix          = trimspace(var.name_prefix)
  secondary_hc_id      = var.secondary_health_check_id != null && var.secondary_health_check_id != "" ? var.secondary_health_check_id : ""
  lambda_function_name = "${trimspace(var.name_prefix)}-handler"
  lambda_build_dir     = "${path.module}/build"
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

resource "null_resource" "lambda_build" {
  count = local.enabled ? 1 : 0

  triggers = {
    handler_hash      = filemd5("${path.module}/src/dr_failover_handler.py")
    requirements_hash = filemd5("${path.module}/src/requirements.txt")
  }

  provisioner "local-exec" {
    command = <<-EOT
      rm -rf ${local.lambda_build_dir}
      mkdir -p ${local.lambda_build_dir}
      python -m pip install -r ${path.module}/src/requirements.txt -t ${local.lambda_build_dir} --quiet --platform manylinux2014_x86_64 --implementation cp --only-binary=:all:
      cp ${path.module}/src/dr_failover_handler.py ${local.lambda_build_dir}/
    EOT
  }
}

data "archive_file" "lambda_package" {
  count = local.enabled ? 1 : 0

  type        = "zip"
  source_dir  = local.lambda_build_dir
  output_path = "${path.module}/dr-failover-handler.zip"

  depends_on = [null_resource.lambda_build]
}

resource "aws_sns_topic" "failover" {
  count    = local.enabled ? 1 : 0
  provider = aws.route53_region

  name = "${local.name_prefix}-sns"
  tags = var.tags
}

resource "aws_sns_topic_policy" "failover_cross_region" {
  count    = local.enabled ? 1 : 0
  provider = aws.route53_region

  arn = aws_sns_topic.failover[0].arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowLambdaSubscribe"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action   = "SNS:Subscribe"
        Resource = aws_sns_topic.failover[0].arn
      },
      {
        Sid    = "AllowCloudWatchPublish"
        Effect = "Allow"
        Principal = {
          Service = "cloudwatch.amazonaws.com"
        }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.failover[0].arn
      }
    ]
  })
}

resource "aws_cloudwatch_metric_alarm" "primary_unhealthy" {
  count    = local.enabled ? 1 : 0
  provider = aws.route53_region

  alarm_name        = "${local.name_prefix}-primary-unhealthy"
  alarm_description = "Route53 primary health check unhealthy - trigger DR failover scaling"

  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  threshold           = 1
  metric_name         = "HealthCheckStatus"
  namespace           = "AWS/Route53"
  statistic           = "Minimum"
  period              = 60
  treat_missing_data  = "breaching"

  dimensions = {
    HealthCheckId = var.primary_health_check_id
  }

  alarm_actions = [aws_sns_topic.failover[0].arn]
  tags          = var.tags
}

resource "aws_iam_role" "lambda" {
  count = local.enabled ? 1 : 0

  name = "${local.name_prefix}-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  count = local.enabled ? 1 : 0

  role       = aws_iam_role.lambda[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_access" {
  count = local.enabled ? 1 : 0

  name = "${local.name_prefix}-lambda-access"
  role = aws_iam_role.lambda[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:GetToken"
        ]
        Resource = [
          "arn:aws:eks:${var.cluster_region}:${data.aws_caller_identity.current.account_id}:cluster/${var.cluster_name}"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "route53:GetHealthCheckStatus",
          "route53:GetHealthCheck",
          "route53:UpdateHealthCheck"
        ]
        Resource = [
          "arn:aws:route53:::healthcheck/${var.primary_health_check_id}",
          "arn:aws:route53:::healthcheck/${coalesce(var.secondary_health_check_id, var.primary_health_check_id)}"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricStatistics"
        ]
        Resource = ["*"]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = [
          "arn:aws:kms:${var.cluster_region}:${data.aws_caller_identity.current.account_id}:key/*"
        ]
        Condition = {
          StringEquals = {
            "kms:ViaService" = "lambda.${var.cluster_region}.amazonaws.com"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:PutParameter"
        ]
        Resource = [
          "arn:aws:ssm:${var.cluster_region}:${data.aws_caller_identity.current.account_id}:parameter/${local.name_prefix}/last-failover-time"
        ]
      }
    ]
  })
}

resource "aws_kms_key" "lambda" {
  count = local.enabled ? 1 : 0

  description             = "KMS key for Lambda environment variable encryption"
  deletion_window_in_days = 7

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "Allow Lambda service to use the key"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "lambda.${var.cluster_region}.amazonaws.com"
          }
        }
      },
      {
        Sid    = "Allow Lambda role to decrypt"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.lambda[0].arn
        }
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })

  tags = var.tags
}

resource "aws_kms_alias" "lambda" {
  count = local.enabled ? 1 : 0

  name          = "alias/${local.name_prefix}-lambda"
  target_key_id = aws_kms_key.lambda[0].key_id
}

# SSM parameter for persisting the failover cooldown timestamp across Lambda
# cold starts.  The Lambda reads/writes this value so the cooldown window
# survives container recycling, scaling events, and redeployments.
resource "aws_ssm_parameter" "cooldown_timestamp" {
  count = local.enabled ? 1 : 0

  name  = "/${local.name_prefix}/last-failover-time"
  type  = "String"
  value = "0"

  # The Lambda overwrites this value on each failover; Terraform should not
  # revert it back to "0" on subsequent applies.
  lifecycle {
    ignore_changes = [value]
  }

  tags = var.tags
}

resource "aws_lambda_function" "failover" {
  count = local.enabled ? 1 : 0

  function_name    = local.lambda_function_name
  role             = aws_iam_role.lambda[0].arn
  handler          = "dr_failover_handler.lambda_handler"
  runtime          = var.lambda_runtime
  filename         = data.archive_file.lambda_package[0].output_path
  source_code_hash = data.archive_file.lambda_package[0].output_base64sha256
  timeout          = var.lambda_timeout_seconds
  memory_size      = var.lambda_memory_mb
  kms_key_arn      = aws_kms_key.lambda[0].arn

  environment {
    variables = {
      CLUSTER_NAME                = var.cluster_name
      CLUSTER_REGION              = var.cluster_region
      CLUSTER_NAMESPACE           = var.cluster_namespace
      TARGET_OPERATOR_REPLICAS    = tostring(var.operator_target_replicas)
      PRIMARY_HEALTH_CHECK_ID     = var.primary_health_check_id
      PRIMARY_HEALTH_CHECK_FQDN   = var.primary_health_check_fqdn
      SECONDARY_HEALTH_CHECK_ID   = local.secondary_hc_id
      SKIP_SECONDARY_HEALTH_CHECK = tostring(var.skip_secondary_health_check)
      HUMIOCLUSTER_NAME           = var.humiocluster_name
      LOG_LEVEL                   = "INFO"

      # Retry configuration
      MAX_RETRIES        = tostring(var.max_retries)
      BASE_DELAY_SECONDS = tostring(var.base_delay_seconds)
      MAX_DELAY_SECONDS  = tostring(var.max_delay_seconds)

      # Pre-failover validation configuration
      PRE_FAILOVER_FAILURE_SECONDS = tostring(var.pre_failover_failure_seconds)
      FAILOVER_COOLDOWN_SECONDS    = tostring(var.failover_cooldown_seconds)
      COOLDOWN_SSM_PARAMETER       = aws_ssm_parameter.cooldown_timestamp[0].name
    }
  }

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "lambda" {
  count = local.enabled ? 1 : 0

  name              = "/aws/lambda/${local.lambda_function_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_permission" "sns_invoke" {
  count = local.enabled ? 1 : 0

  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.failover[0].function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.failover[0].arn
}

resource "aws_sns_topic_subscription" "lambda" {
  count    = local.enabled ? 1 : 0
  provider = aws.route53_region

  topic_arn = aws_sns_topic.failover[0].arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.failover[0].arn
}

# Grant the Lambda IAM role access to the cluster via EKS Access Entries
resource "aws_eks_access_entry" "lambda" {
  count = local.enabled ? 1 : 0

  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.lambda[0].arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "lambda" {
  count = local.enabled ? 1 : 0

  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.lambda[0].arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy"

  access_scope {
    type       = "namespace"
    namespaces = [var.cluster_namespace]
  }

  depends_on = [aws_eks_access_entry.lambda]
}
