# Backend configuration for PRIMARY workspace
#
# Usage:
#   terraform workspace select primary
#   terraform init -backend-config=backend-configs/primary-aws.hcl
#
# State is stored at:
#   s3://placeholder-backend/env:/primary/env:/logscale-aws-eks
#
# IMPORTANT: This backend config is for the 'primary' workspace only.
# Do not use with secondary workspace - use secondary-aws.hcl instead.

bucket  = "your-terraform-state-bucket"
region  = "eu-central-1"
key     = "env:/logscale-aws-eks"
profile = "your-aws-profile"  # change to your AWS CLI profile

# Optional: Enable state locking with DynamoDB
# dynamodb_table = "terraform-state-lock"

# Enable server-side encryption
encrypt = true
