output "s3_storage_encryption_key" {
  description = "S3 storage encryption key for LogScale buckets, sourced from the kubernetes pre-install module."
  value       = module.pre-install.s3_storage_encryption_key_value
  sensitive   = true
}

output "s3_bucket_id" {
  description = "The S3 bucket ID/name for LogScale storage"
  value       = module.eks.logscale_s3_bucket_id
}

output "s3_bucket_region" {
  description = "The AWS region where the S3 bucket is located"
  value       = var.aws_region
}

output "s3_encryption_key_secret_name" {
  description = "The Kubernetes secret name containing the S3 encryption key"
  value       = module.pre-install.s3_storage_encryption_key_k8s_secret_name
}

output "cluster_name" {
  description = "The EKS cluster name"
  value       = var.cluster_name
}

output "primary_health_check_id" {
  description = "Route53 health check ID for the primary cluster (only set when manage_global_dns=true)"
  value       = var.manage_global_dns ? module.global-dns.primary_health_check_id : null
}

output "secondary_health_check_id" {
  description = "Route53 health check ID for the secondary cluster TCP check (only set when manage_global_dns=true)"
  value       = var.manage_global_dns ? module.global-dns.secondary_health_check_id : null
}