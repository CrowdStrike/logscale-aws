terraform {
  required_version = ">= 1.5.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.10.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.32.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.13.2"
    }
    random = {
      source = "hashicorp/random"
      version = ">= 3.7.2"
    }
  }

  backend "s3" {
    bucket         = "logscale-tf-state"  # Your S3 backend bucket name
    key            = "state/terraform.tfstate"
    region         = "eu-central-1"
    dynamodb_table = "logscale-tf-state-locks" # Your DynamoDB Table name
    encrypt        = true
    profile        = "logscale-aws" # Your AWS profile
  }
}
