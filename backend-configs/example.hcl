# Example backend configuration for AWS S3
#
# Copy this file to primary-aws.hcl or secondary-aws.hcl
# and update with your values.
#
# Usage:
#   terraform workspace select primary  # or: terraform workspace new primary
#   terraform init -backend-config=backend-configs/primary-aws.hcl
#

bucket  = "your-terraform-state-bucket"
region  = "eu-central-1"
key     = "env:/logscale-aws-eks"
profile = "your-aws-profile"  # change to your AWS CLI profile

# Optional: Enable state locking with DynamoDB
# dynamodb_table = "terraform-state-lock"

# Enable server-side encryption
encrypt = true
