module "s3_logs_bucket_msk" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.1.2"

  bucket_prefix = "${var.msk_cluster_name}-"

  acl                      = "log-delivery-write"
  control_object_ownership = true
  object_ownership         = "ObjectWriter"

  force_destroy = true

  attach_deny_insecure_transport_policy = true
  attach_lb_log_delivery_policy         = true
  block_public_policy                   = true
  block_public_acls                     = true
  restrict_public_buckets               = true

  versioning = {
    status     = true
    mfa_delete = false
  }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  logging = {
    target_bucket = module.s3_logs_bucket_msk.s3_bucket_id
    target_prefix = "log/"
    target_object_key_format = {
      partitioned_prefix = {
        partition_date_source = "DeliveryTime"
      }
    }
  }

  tags = var.tags
}
