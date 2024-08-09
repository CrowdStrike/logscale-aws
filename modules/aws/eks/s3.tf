module "s3_logs_bucket_logscale" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.1.2"

  bucket        = var.s3_bucket_prefix != "" ? null : var.cluster_name
  bucket_prefix = var.s3_bucket_prefix != "" ? var.s3_bucket_prefix : null

  acl                      = "private"
  control_object_ownership = true
  object_ownership         = "ObjectWriter"
  block_public_policy      = true
  block_public_acls        = true
  restrict_public_buckets  = true

  force_destroy = true

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
    enabled    = true
    mfa_delete = false
  }

  logging = {
    target_bucket = module.s3_logs_bucket_logscale.s3_bucket_id
    target_prefix = "log/"
    target_object_key_format = {
      partitioned_prefix = {
        partition_date_source = "DeliveryTime"
      }
    }
  }


  tags = var.tags
}
