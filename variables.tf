variable "aws_region" {
  description = "The AWS region to create resources in."
  type        = string
}

variable "aws_profile" {
  description = "The AWS profile to use for the EKS cluster"
  type        = string
}

variable "tags" {
  description = "map pf tags to be applied to AWS resources"
  type        = map(string)
}

variable "vpc_name" {
  description = "The name of the VPC."
  type        = string
}


variable "vpc_cidr" {
  description = "The CIDR block for the VPC."
  type        = string
}


variable "cluster_name" {
  description = "The name of the EKS cluster."
  type        = string
}

variable "cluster_version" {
  description = "The Kubernetes version for the EKS cluster."
  type        = string
}

variable "vpc_cni_addon_version" {
  description = "VPC CNI addon version. If not specified, uses most_recent."
  type        = string
  default     = null
}

variable "ebs_csi_addon_version" {
  description = "EBS CSI driver addon version. If not specified, uses most_recent."
  type        = string
  default     = null
}

variable "ami_type" {
  description = "The AMI type of the logscale managed node group."
  type        = string
}

variable "ami_release_version" {
  description = "The AMI release version for EKS managed node groups (e.g., 1.33.5-20251120). If not specified, uses the latest AMI."
  type        = string
  default     = null
}

variable "route53_record_ttl" {
  description = "TTL of the Logscale route53 record"
  type        = number
}

variable "manage_global_dns" {
  description = "When true, manage global DNS failover records for Logscale"
  type        = bool
  default     = false
}

variable "global_logscale_hostname" {
  description = "Short hostname for the global Logscale FQDN within the hosted zone (for example: \"logscale-dr\")"
  type        = string
  default     = ""
}

variable "primary_logscale_hostname" {
  description = "Short hostname for the primary Logscale cluster within the hosted zone (for example: \"logscale-dr-primary\")"
  type        = string
  default     = ""
}

variable "secondary_logscale_hostname" {
  description = "Short hostname for the secondary Logscale cluster within the hosted zone (for example: \"logscale-dr-secondary\")"
  type        = string
  default     = ""
}

variable "logscale_namespace" {
  description = "The namespace used by logscale."
  type        = string
}

variable "cm_namespace" {
  description = "The namespace used by cert-manager."
  type        = string

}

variable "cm_repo" {
  description = "The cert-manager repository."
  type        = string
}

variable "cm_version" {
  description = "The cert-manager helm chart version"
  type        = string
}

variable "logscale_operator_repo" {
  description = "The logscale repository."
  type        = string
}

variable "logscale_image_version" {
  description = "Logscale docker image version"
  type        = string
}

variable "issuer_kind" {
  description = "Certificates issuer kind for the Logscale cluster."
  type        = string
}

variable "issuer_name" {
  description = "Certificates issuer name for the Logscale Cluster"
  type        = string
}

variable "issuer_email" {
  description = "Certificates issuer email for the Logscale Cluster"
  type        = string
}

variable "issuer_private_key" {
  description = "Certificates issuer private key for the Logscale Cluster"
  type        = string
}

variable "ca_server" {
  description = "Certificate Authority Server."
  type        = string
}

variable "use_own_certificate_for_ingress" {
  default     = false
  type        = bool
  description = "Set to true if you plan to bring your own certificate for logscale ingest/ui access."
}

variable "external_dns_chart_version" {
  description = "The version of the external-dns Helm chart to install"
  type        = string
}

variable "alb_controller_version" {
  description = "AWS Load balancer controller helm chart version."
  type        = string
}

variable "gateway_api_version" {
  description = "Gateway API helm chart version."
  type        = string
}

variable "topo_lvm_chart_version" {
  description = "TopoLVM helm chart version."
  type        = string
}

variable "humio_operator_chart_version" {
  description = "Humio Operator helm chart version"
  type        = string
}

variable "humio_operator_version" {
  description = "Humio Operator version"
  type        = string
}

variable "humio_operator_extra_values" {
  description = "Resource Management for logscale pods"
  type        = map(string)
}

variable "logscale_cluster_type" {
  description = "Logscale cluster type"
  type        = string

  validation {
    condition     = contains(["basic", "ingress", "dedicated-ui", "advanced"], var.logscale_cluster_type)
    error_message = "logscale_cluster_type must be one of: basic, ingress, dedicated-ui or advanced"
  }
}

variable "logscale_cluster_size" {
  description = "Logscale cluster size"
  default     = "xsmall"
  type        = string
  validation {
    condition     = contains(["xsmall", "small", "medium", "large", "xlarge"], var.logscale_cluster_size)
    error_message = "logscale_cluster_size must be one of: xsmall, small, medium, large, or xlarge"
  }
}

variable "extra_user_logscale_envvars" {
  type = list(object({
    name  = string,
    value = optional(string)
    valueFrom = optional(object({
      secretKeyRef = object({
        name = string
        key  = string
      })
    }))
  }))
  description = "Extra environment variables passed into the HumioCluster resource spec definition that will be used for all created logscale instances. Supports string values and kubernetes secret refs. Will override any values defined by default in the configuration."
  default     = []
}

variable "s3_recover_from_replace_region" {
  description = "Value for S3_RECOVER_FROM_REPLACE_REGION when configuring DR recovery."
  type        = string
  default     = null
}

variable "s3_recover_from_replace_bucket" {
  description = "Value for S3_RECOVER_FROM_REPLACE_BUCKET."
  type        = string
  default     = null
}

variable "s3_recover_from_bucket" {
  description = "Value for S3_RECOVER_FROM_BUCKET."
  type        = string
  default     = null
}

variable "s3_recover_from_region" {
  description = "Value for S3_RECOVER_FROM_REGION."
  type        = string
  default     = null
}

variable "s3_recover_from_encryption_key_secret_name" {
  description = "Secret name referenced by S3_RECOVER_FROM_ENCRYPTION_KEY."
  type        = string
  default     = null
}

variable "s3_recover_from_encryption_key_secret_key" {
  description = "Secret key referenced by S3_RECOVER_FROM_ENCRYPTION_KEY."
  type        = string
  default     = null
}

variable "provision_kafka_servers" {
  description = "Set this to true to provision strimzi kafka within this kubernetes cluster. It should be false if you are bringing your own kafka implementation."
  default     = false
  type        = bool
}

variable "strimzi_operator_chart_version" {
  type        = string
  description = "Helm chart version for installing strimzi."
  default     = ""
}

variable "strimzi_operator_version" {
  type        = string
  description = "Strimzi operator version for resource definition installation."
  default     = ""
}

variable "kafka_version" {
  description = "Specify the desired Kafka software version"
  type        = string
}

variable "msk_cluster_name" {
  description = "Name of the MSK cluster"
  type        = string
}

variable "zone_name" {
  description = "Route53 hosted zone domain name"
  type        = string
}

variable "humiocluster_license" {
  description = "Logscale license"
  type        = string
  sensitive   = true
}

variable "hostname" {
  description = "Hostname of the Logscale cluster"
  type        = string
}

variable "eks_s3_bucket_prefix" {
  description = "The prefix of the LogScale S3 bucket"
  type        = string
  default     = ""
}

variable "eks_s3_bucket_name" {
  description = "Explicit S3 bucket name for LogScale storage (deterministic). When set, overrides eks_s3_bucket_prefix."
  type        = string
  default     = null
}

variable "existing_s3_encryption_key" {
  description = "Optional S3 bucket encryption key reused by DR clusters. When null and dr=\"standby\", the key is fetched from the primary cluster via primary_remote_state_config."
  type        = string
  default     = null
}

variable "primary_remote_state_config" {
  description = "Remote state configuration for accessing primary cluster outputs. Required when dr=\"standby\" to fetch the S3 encryption key."
  type = object({
    backend   = string
    workspace = optional(string)
    config    = map(any)
  })
  default = null
}

variable "kubeconfig_filepath" {
  description = "The filepath where the EKS kubeconfig file will be placed"
  type        = string
  default     = ""
}

variable "dr" {
  description = "Disaster Recovery mode: 'active' for primary DR cluster, 'standby' for secondary DR cluster, or '' (empty) for a cluster not participating in DR."
  type        = string
  default     = "active"

  validation {
    condition     = contains(["", "active", "standby"], var.dr)
    error_message = "dr must be '', 'active', or 'standby'"
  }
}

variable "dr_use_dedicated_routing" {
  description = <<-EOT
    Enable dedicated pool routing (UI/Ingest pods) for DR clusters.

    Default is true - normal pool-specific routing for optimized traffic distribution.

    Set to false ONLY during DR promotion to enable zero-downtime failover:
    - When false: Service selectors use { "app.kubernetes.io/name" = "humio" } to match ALL pods
    - Traffic continues to existing digest pod while UI/Ingest pods scale up

    Two-phase DR promotion workflow:
    1. First apply: Set dr="active" with dr_use_dedicated_routing=false
       - Zero-downtime: traffic goes to digest pod during UI/Ingest scale-up
    2. Second apply: Set dr_use_dedicated_routing=true (or remove the override)
       - Traffic routes to dedicated UI/Ingest pools

    For non-DR clusters (dr=""), this variable is ignored - pool-specific routing is always used.
  EOT
  type        = bool
  default     = true
}

variable "expected_workspace" {
  description = "Expected Terraform workspace name for this configuration (e.g., 'default' for primary, 'secondary' for secondary)"
  type        = string
  default     = null

  validation {
    condition     = var.expected_workspace == null || can(regex("^[a-zA-Z0-9_-]+$", var.expected_workspace))
    error_message = "expected_workspace must be a valid workspace name (alphanumeric, hyphens, underscores)"
  }
}

variable "dr_primary_s3_bucket" {
  description = "DR peer cluster's S3 bucket for cross-region read access. For secondary cluster, this is the primary bucket. For primary cluster, this is the secondary bucket."
  type        = string
  default     = null
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
}

variable "dr_humiocluster_name" {
  description = "Name of the HumioCluster resource to manage"
  type        = string
  default     = ""
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

variable "dr_failover_lambda_enabled" {
  description = "Enable Lambda-based DR failover automation for automatic HumioCluster scaling on DNS failover"
  type        = bool
  default     = true
}

variable "lambda_runtime" {
  description = "Python runtime version for Lambda (e.g., python3.10, python3.14). Should match your local Python version."
  type        = string
  default     = "python3.14"
}


variable "dr_failover_lambda_target_node_count" {
  description = "Target nodeCount to scale HumioCluster to during failover (typically 1 for standby)"
  type        = number
  default     = 1
}

variable "dr_failover_lambda_timeout" {
  description = "Lambda function timeout in seconds"
  type        = number
  default     = 60
}

variable "dr_failover_lambda_memory_mb" {
  description = "Lambda function memory allocation in MB"
  type        = number
  default     = 256
}

variable "dr_failover_lambda_log_retention_days" {
  description = "CloudWatch log retention for Lambda function in days"
  type        = number
  default     = 7
}

variable "dr_failover_lambda_skip_secondary_health_check" {
  description = "Skip the secondary health check gate in the failover Lambda (useful for DR simulations when standby is scaled to 0)."
  type        = bool
  default     = false
}

variable "dr_failover_lambda_pre_failover_failure_seconds" {
  description = "Minimum consecutive seconds the primary must be failing before the Lambda triggers failover. Set to 0 for immediate failover (testing only). Lower values = faster failover but more susceptible to transient issues."
  type        = number
  default     = 180

  validation {
    condition     = var.dr_failover_lambda_pre_failover_failure_seconds >= 0 && var.dr_failover_lambda_pre_failover_failure_seconds <= 600
    error_message = "dr_failover_lambda_pre_failover_failure_seconds must be between 0 and 600"
  }
}

variable "dr_primary_health_check_id" {
  description = "Route53 health check ID for the primary cluster (required for Lambda failover on standby)"
  type        = string
  default     = ""
}

variable "dr_secondary_health_check_id" {
  description = "Route53 health check ID for the secondary cluster (required for Lambda failover on standby)"
  type        = string
  default     = ""
}

