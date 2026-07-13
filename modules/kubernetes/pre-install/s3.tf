# Generate an encryption key that will be used by LogScale to encrypt the data in the S3 bucket
resource "random_password" "s3_encryption_password" {
  # Only generate a new key when not in standby mode.
  # In standby, the key must be provided from the primary (remote state).
  count   = var.existing_s3_encryption_key == null && var.dr != "standby" ? 1 : 0
  length  = 64
  special = false
}

locals {
  generated_s3_encryption_key = try(random_password.s3_encryption_password[0].result, null)
  s3_encryption_key           = coalesce(var.existing_s3_encryption_key, local.generated_s3_encryption_key)
}

resource "kubernetes_secret_v1" "s3_storage_encryption_key" {
  metadata {
    name      = "${var.cluster_name}-s3-storage-encryption"
    namespace = var.logscale_namespace
  }
  data = {
    s3-storage-encryption-key = local.s3_encryption_key
  }

  lifecycle {
    precondition {
      condition     = var.dr != "standby" || var.existing_s3_encryption_key != null
      error_message = "In DR standby mode, an existing_s3_encryption_key must be supplied (from the primary cluster's remote state)."
    }
  }
}
