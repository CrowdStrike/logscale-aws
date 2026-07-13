# Backend configuration for SECONDARY workspace
#
# Usage:
#   terraform workspace select secondary  # or: terraform workspace new secondary
#   terraform init -backend-config=backend-configs/secondary-aws.hcl
#
# S3 backend automatically stores state per workspace at:
#   s3://placeholder-backend/env:/logscale-aws-eks/secondary/terraform.tfstate
#
# IMPORTANT: This backend config is for the 'secondary' workspace only.
# Do not use with primary workspace - use primary-aws.hcl instead.

bucket  = "your-terraform-state-bucket"
region  = "eu-central-1"
key     = "env:/logscale-aws-eks"
profile = "your-aws-profile"  # change to your AWS CLI profile

# Optional: Enable state locking with DynamoDB
# dynamodb_table = "terraform-state-lock"

# Enable server-side encryption
encrypt = true
