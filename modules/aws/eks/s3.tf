module "s3_logs_bucket_logscale" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 5.5.0"

  # Prefer explicit bucket name when provided for deterministic naming.
  # Fallback: if prefix is provided, AWS will append a random suffix; else use cluster_name.
  bucket        = (var.s3_bucket_name != null && var.s3_bucket_name != "") ? var.s3_bucket_name : (var.s3_bucket_prefix != "" ? null : var.cluster_name)
  bucket_prefix = (var.s3_bucket_name != null && var.s3_bucket_name != "") ? null : (var.s3_bucket_prefix != "" ? var.s3_bucket_prefix : null)

  acl                      = "private"
  control_object_ownership = true
  object_ownership         = "ObjectWriter"
  block_public_policy      = true
  block_public_acls        = true
  restrict_public_buckets  = true

  force_destroy = var.dr == "standby"

  lifecycle_rule = [
    {
      id      = "log"
      enabled = true
      noncurrent_version_expiration = {
        days = 1
      }
    },
  ]
  versioning = {
    enabled    = false
    mfa_delete = false
  }

  tags = var.tags
}
