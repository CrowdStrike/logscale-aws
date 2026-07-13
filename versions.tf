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
      source  = "hashicorp/random"
      version = ">= 3.7.2"
    }
  }
}
