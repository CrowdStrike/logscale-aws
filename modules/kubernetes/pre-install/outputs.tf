output "s3_storage_encryption_key_k8s_secret_name" {
  description = "The name of the kubernetes secret holding th s3 storage encryption key"
  value       = kubernetes_secret_v1.s3_storage_encryption_key.metadata[0].name
}

output "s3_storage_encryption_key_value" {
  description = "The S3 storage encryption key applied to the bucket-storage-replica secret."
  value       = local.s3_encryption_key
  sensitive   = true
}
