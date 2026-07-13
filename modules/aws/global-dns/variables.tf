variable "zone_name" {
  description = "Route53 hosted zone domain name"
  type        = string
}

variable "route53_record_ttl" {
  description = "TTL of the global Logscale Route53 record"
  type        = number
}

variable "manage_global_dns" {
  description = "When true, this module manages the global Logscale failover DNS records."
  type        = bool
}

variable "global_logscale_hostname" {
  description = "Short hostname (record name) for the global Logscale FQDN within the hosted zone (for example: \"logscale-dr\")."
  type        = string
}

variable "primary_logscale_hostname" {
  description = "Short hostname (record name) for the primary Logscale cluster within the hosted zone (for example: \"logscale-dr-primary\")."
  type        = string
}

variable "secondary_logscale_hostname" {
  description = "Short hostname (record name) for the secondary Logscale cluster within the hosted zone (for example: \"logscale-dr-secondary\")."
  type        = string
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
