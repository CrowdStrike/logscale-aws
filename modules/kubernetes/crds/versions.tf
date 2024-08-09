terraform {
  required_version = ">= 1.5.7"

  required_providers {

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.31.0"
    }

    null = {
      source  = "hashicorp/null"
      version = ">= 3.2"
    }

    http = {
      source  = "hashicorp/http"
      version = "3.4.2"
    }
  }
}
