variable "aws_region" {
  description = "The AWS region to create resources in."
  type        = string
}

variable "aws_profile" {
  description = "The AWS profile to use for the EKS cluster"
  type        = string
}

variable "cluster_endpoint" {
  description = "Endpoint for your Kubernetes API server"
  type        = string
}

variable "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data required to communicate with the cluster"
  type        = string
}

variable "cluster_name" {
  description = "The name of the EKS cluster."
  type        = string
}

variable "hostname" {
  description = "Hostname of the Logscale cluster"
  type        = string
}

variable "zone_name" {
  description = "Route53 hosted zone domain name"
  type        = string
}

variable "logscale_namespace" {
  description       = "The kubernetes namespace used by logscale resources."
  type              = string
}

variable "service_account_aws_iam_role_arn" {
  description = "Amazon Resource Name (ARN) for the service account role."
  type        = string
}

variable "alb_controller_repo" {
  description = "AWS Load balancer controller helm chart repository."
  type        = string
  default     = "https://aws.github.io/eks-charts"
}

variable "alb_controller_version" {
  description = "AWS Load balancer controller helm chart version."
  type        = string
}

variable "eks_lb_controller_role_arn" {
  description = "ALB Controller IAM role"
  type        = string
}

variable "external_dns_iam_role_arn" {
  description = "The ARN of the IAM role used by ExternalDNS"
  type        = string
}

variable "external_dns_chart_version" {
  description = "The version of the external-dns Helm chart to install"
  type        = string
  default     = "1.14.5"
}

variable "external_dns_repository" {
  description = "The Helm repository URL for the external-dns chart"
  type        = string
  default     = "https://kubernetes-sigs.github.io/external-dns/"
}

variable "kubeconfig_filepath" {
  description = ""
  type        = string
}
