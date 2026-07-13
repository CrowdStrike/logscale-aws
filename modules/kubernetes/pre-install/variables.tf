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
  description = "The kubernetes namespace used by logscale resources."
  type        = string
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

variable "existing_s3_encryption_key" {
  description = "Optional S3 encryption key to seed the bucket-storage-replica secret; when unset a new key is generated."
  type        = string
  default     = null
}

variable "dr" {
  description = "Disaster Recovery mode: 'active' for primary DR cluster, 'standby' for secondary DR cluster, or '' (empty) for a cluster not participating in DR. Controls when the S3 encryption key must come from remote state."
  type        = string
  default     = "active"
  validation {
    condition     = contains(["", "active", "standby"], var.dr)
    error_message = "dr must be '', 'active', or 'standby'"
  }
}

variable "dr_traffic_detector_enabled" {
  description = "Enable DR traffic detector deployment for automatic digest scaling on DNS failover"
  type        = bool
  default     = true
}

variable "dr_global_dns" {
  description = "Global DNS name used for failover detection (e.g., logscale-dr.example.com)"
  type        = string
  default     = ""

  validation {
    condition     = var.dr != "standby" || !var.dr_traffic_detector_enabled || trimspace(var.dr_global_dns) != ""
    error_message = "dr_global_dns must be set when dr=\"standby\" and dr_traffic_detector_enabled=true."
  }
}

variable "dr_primary_dns" {
  description = "Primary cluster DNS name (e.g., logscale-dr-primary.example.com)"
  type        = string
  default     = ""
}

variable "dr_secondary_dns" {
  description = "Secondary cluster DNS name (e.g., logscale-dr-secondary.example.com)"
  type        = string
  default     = ""

  validation {
    condition     = var.dr != "standby" || !var.dr_traffic_detector_enabled || trimspace(var.dr_secondary_dns) != ""
    error_message = "dr_secondary_dns must be set when dr=\"standby\" and dr_traffic_detector_enabled=true."
  }
}

variable "dr_humiocluster_name" {
  description = "Name of the HumioCluster resource to manage"
  type        = string
  default     = ""

  validation {
    condition     = var.dr != "standby" || !var.dr_traffic_detector_enabled || trimspace(var.dr_humiocluster_name) != ""
    error_message = "dr_humiocluster_name must be set when dr=\"standby\" and dr_traffic_detector_enabled=true."
  }
}

variable "dr_check_interval" {
  description = "DNS check interval in seconds"
  type        = number
  default     = 5
}

variable "dr_consecutive_checks" {
  description = "Number of consecutive checks required before scaling"
  type        = number
  default     = 3
}

variable "dr_traffic_detector_image" {
  description = "Container image for the DR traffic detector (must include kubectl and dig)"
  type        = string
  default     = "bitnami/kubectl:1.32.0"
}

variable "acm_certificate_arn" {
  description = "ACM certificate ARN for HTTPS termination"
  type        = string
}
