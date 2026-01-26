# Generate an encryption key that will be used by LogScale to encrypt the data in the S3 bucket
resource "random_password" "s3_encryption_password" {
  length  = 64
  special = false
}

resource "kubernetes_secret_v1" "s3_storage_encryption_key" {
  metadata {
    name      = "${var.cluster_name}-s3-storage-encryption"
    namespace = var.logscale_namespace
  }
  data = {
    s3-storage-encryption-key = random_password.s3_encryption_password.result
  }
  depends_on = [null_resource.logscale_ns]
}
