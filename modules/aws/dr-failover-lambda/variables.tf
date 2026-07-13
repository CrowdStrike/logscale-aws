variable "enabled" {
  description = "Enable the DR failover Lambda. Expects Route53 health checks to be managed and an accessible EKS cluster."
  type        = bool
  default     = false
}

variable "lambda_runtime" {
  description = "Python runtime version for Lambda (e.g., python3.10, python3.14). Should match your local Python version."
  type        = string
  default     = "python3.14"
}

variable "primary_health_check_id" {
  description = "Route53 health check ID for the primary ingest endpoint."
  type        = string
  default     = null
}

variable "primary_health_check_fqdn" {
  description = "Original FQDN of the primary health check. Used by the Lambda to restore the health check during manual failback."
  type        = string
}

variable "secondary_health_check_id" {
  description = "Route53 health check ID for the secondary ingest endpoint."
  type        = string
  default     = null
}

variable "cluster_name" {
  description = "Name of the standby EKS cluster to patch (HumioCluster name is assumed to match)."
  type        = string
}

variable "cluster_region" {
  description = "AWS region for the standby EKS cluster."
  type        = string
}

variable "cluster_namespace" {
  description = "Namespace containing the HumioCluster."
  type        = string
  default     = "logging"
}

variable "operator_target_replicas" {
  description = "Humio operator replica count to enforce on failover (set to 1 to bring operator online)."
  type        = number
  default     = 1
}

variable "name_prefix" {
  description = "Prefix for created resources (SNS topic, Lambda, alarm)."
  type        = string
  default     = "logscale-dr-failover"
}

variable "tags" {
  description = "Tags to apply."
  type        = map(string)
  default     = {}
}

variable "lambda_timeout_seconds" {
  description = "Lambda timeout in seconds."
  type        = number
  default     = 60
}

variable "lambda_memory_mb" {
  description = "Lambda memory size in MB."
  type        = number
  default     = 256
}

variable "log_retention_days" {
  description = "CloudWatch log retention for the Lambda."
  type        = number
  default     = 14
}

variable "skip_secondary_health_check" {
  description = "Skip secondary health check gating; useful for DR simulations where the standby cluster is intentionally scaled to 0."
  type        = bool
  default     = false
}

variable "humiocluster_name" {
  description = "Name of the HumioCluster CR (used for TLS secret cleanup during failover to prevent CA mismatch)"
  type        = string
  default     = ""
}

# =============================================================================
# Retry Configuration
# =============================================================================

variable "max_retries" {
  description = "Maximum number of retry attempts for Kubernetes API calls (retries on HTTP 429, 500, 502, 503, 504 and connection errors)"
  type        = number
  default     = 3

  validation {
    condition     = var.max_retries >= 0 && var.max_retries <= 10
    error_message = "max_retries must be between 0 and 10"
  }
}

variable "base_delay_seconds" {
  description = "Base delay in seconds before first retry (doubles each subsequent attempt with exponential backoff)"
  type        = number
  default     = 1.0

  validation {
    condition     = var.base_delay_seconds >= 0.1 && var.base_delay_seconds <= 10
    error_message = "base_delay_seconds must be between 0.1 and 10"
  }
}

variable "max_delay_seconds" {
  description = "Maximum delay cap in seconds between retries (prevents excessive wait times)"
  type        = number
  default     = 30.0

  validation {
    condition     = var.max_delay_seconds >= 1 && var.max_delay_seconds <= 60
    error_message = "max_delay_seconds must be between 1 and 60"
  }
}

# =============================================================================
# Pre-Failover Validation Configuration
# =============================================================================

variable "pre_failover_failure_seconds" {
  description = "Minimum consecutive seconds the primary must be failing before triggering failover. Set to 0 for immediate failover (testing only)."
  type        = number
  default     = 180

  validation {
    condition     = var.pre_failover_failure_seconds >= 0 && var.pre_failover_failure_seconds <= 600
    error_message = "pre_failover_failure_seconds must be between 0 and 600"
  }
}

variable "failover_cooldown_seconds" {
  description = "Minimum time between failover attempts to prevent flapping (seconds). Set to 0 to disable."
  type        = number
  default     = 300

  validation {
    condition     = var.failover_cooldown_seconds >= 0 && var.failover_cooldown_seconds <= 3600
    error_message = "failover_cooldown_seconds must be between 0 and 3600"
  }
}
