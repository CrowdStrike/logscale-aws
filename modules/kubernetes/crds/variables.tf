variable "cluster_endpoint" {
  description = "Endpoint for your Kubernetes API server"
  type        = string
}

variable "cm_crds_url" {
  description = "Cert Manager CRDs URL"
  type        = string
  default     = "https://github.com/cert-manager/cert-manager/releases/download/v1.14.5/cert-manager.crds.yaml"
}

variable "humio_operator_version" {
  description = "Humio Operator version"
  type        = string
}
