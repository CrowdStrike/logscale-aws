terraform {
  required_providers {
    kubernetes = {
      source                = "hashicorp/kubernetes"
      configuration_aliases = [kubernetes]
    }
    helm = {
      source                = "hashicorp/helm"
      configuration_aliases = [helm]
    }
    random = {
      source                = "hashicorp/random"
      configuration_aliases = [random]
    }
  }
}
