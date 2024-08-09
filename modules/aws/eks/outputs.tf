output "cluster_endpoint" {
  description = "Endpoint for your Kubernetes API server"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data required to communicate with the EKS cluster"
  value       = module.eks.cluster_certificate_authority_data
}

output "cluster_name" {
  description = "The EKS cluster name"
  value       = module.eks.cluster_name
}

output "acm_certificate_arn" {
  description = "The Amazon Resource Name (ARN) of the ACM certificate issued by ingress"
  value       = aws_acm_certificate.logscale_cert.arn
}

output "logscale_s3_bucket_id" {
  description = "Logscale S3 bucket name"
  value       = module.s3_logs_bucket_logscale.s3_bucket_id
}

output "service_account_aws_iam_role_arn" {
  description = "The Amazon Resource Name (ARN) of the IAM role for the logscale service account"
  value       = aws_iam_role.role_eks_logscale.arn
}

output "eks_lb_controller_role_arn" {
  description = "The Amazon Resource Name (ARN) of the IAM role for the LB controller"
  #value       = aws_iam_role.eks_load_balancer_controller.arn
  value = module.iam_eks_role_lb_controller.iam_role_arn
}

output "external_dns_iam_role_arn" {
  description = "The ARN of the IAM role used by ExternalDNS"
  value       = aws_iam_role.external_dns.arn
}
