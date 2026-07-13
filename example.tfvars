# =============================================================================
# LogScale AWS Terraform Configuration - Example tfvars
# =============================================================================
# This file provides a template for configuring LogScale on AWS.
# Copy this file and customize for your deployment:
#   - primary.tfvars   (dr="active", manages global DNS)
#   - secondary.tfvars (dr="standby", DR automation)
#   - single.tfvars    (dr="", standalone cluster)
# =============================================================================

# =============================================================================
# WORKSPACE VALIDATION
# Must match terraform workspace name - prevents applying wrong config
# =============================================================================
# workspace_name = "primary" # Options: "primary", "secondary", "single", or custom

# =============================================================================
# AWS AUTHENTICATION
# Required for all AWS API operations
# =============================================================================
aws_region  = "us-west-2"
aws_profile = "logscale-aws"

# =============================================================================
# NETWORKING
# IMPORTANT: VPC CIDRs must be unique per cluster in the same account/region
# Suggested allocation:
#   Primary:   10.0.0.0/16
#   Secondary: 10.1.0.0/16
#   Single:    10.2.0.0/16
# =============================================================================
vpc_name = "logscale-vpc"
vpc_cidr = "10.0.0.0/16"

# =============================================================================
# EKS CLUSTER CONFIGURATION
# =============================================================================
cluster_name    = "logscale-eks"
cluster_version = "1.32"
ami_type        = "AL2023_x86_64_STANDARD"

# =============================================================================
# LOGSCALE APPLICATION
# =============================================================================
logscale_cluster_type  = "advanced" # Options: "basic", "advanced"
logscale_cluster_size  = "medium"   # Options: "xsmall", "small", "medium", "large"
logscale_image_version = "1.194.0"
logscale_namespace     = "logging"

# License Key (JWT format)
humiocluster_license = "eyJ0eXAiOiJKV1QiLCJhbGciOiJFUzUxMiJ9.example..."

# =============================================================================
# DNS CONFIGURATION
# =============================================================================
zone_name          = "example.humio.net" # Must be delegated to Route53
hostname           = "logscale"
route53_record_ttl = 60

# =============================================================================
# S3 STORAGE
# =============================================================================
eks_s3_bucket_prefix = "logscale-s3"

# Optional: supply a pre-existing S3 encryption key (mostly for DR workspaces)
# existing_s3_encryption_key = "replace-with-primary-key"

# =============================================================================
# DR CONFIGURATION
# =============================================================================
# Options:
#   "active"  - Primary in DR pair (manages global DNS, health checks)
#   "standby" - Secondary in DR pair (DR automation, reads from primary bucket)
#   ""        - Standalone cluster (no DR infrastructure)
dr = "active"

# Two-Phase Promotion (used when promoting standby to active)
# Phase 1: Set dr="active" and dr_use_dedicated_routing=false
#          Generic selectors match ALL pods - zero downtime during scale-up
# Phase 2: Set dr_use_dedicated_routing=true after UI/Ingest pods are ready
#          Pool-specific selectors for optimal routing
# Default: true (pool-specific routing for normal production operation)
dr_use_dedicated_routing = true

# -----------------------------------------------------------------------------
# Global DNS (only set manage_global_dns=true on ONE cluster)
# -----------------------------------------------------------------------------
manage_global_dns = true # true for primary/single, false for secondary

# Hostnames for DR failover DNS steering
global_logscale_hostname    = "logscale"           # Global FQDN for clients
primary_logscale_hostname   = "logscale-primary"   # Direct access to primary
secondary_logscale_hostname = "logscale-secondary" # Direct access to secondary

# DNS names for traffic detection
dr_global_dns    = "" # e.g., "logscale.example.humio.net"
dr_primary_dns   = "" # e.g., "logscale-primary.example.humio.net"
dr_secondary_dns = "" # e.g., "logscale-secondary.example.humio.net"

# -----------------------------------------------------------------------------
# Cross-Region S3 Access (required for DR)
# Primary needs read access to secondary bucket; Secondary needs read access to primary
# -----------------------------------------------------------------------------
# dr_primary_s3_bucket = "logscale-s3-secondary-bucket-name"  # Peer cluster's bucket

# -----------------------------------------------------------------------------
# Remote State (SECONDARY only)
# Used to fetch encryption key, health check IDs, and S3 bucket info from primary
# CRITICAL: workspace must match the primary's Terraform workspace name
# CRITICAL: key must match the primary's backend-config key value exactly
# -----------------------------------------------------------------------------
# primary_remote_state_config = {
#   backend   = "s3"
#   workspace = "primary"          # Must match primary's Terraform workspace
#   config = {
#     bucket  = "your-terraform-state-bucket"
#     key     = "env:/logscale-aws-eks" # Must match primary's backend-config key
#     region  = "us-west-2"
#     profile = "your-aws-profile"
#     encrypt = true
#   }
# }

# -----------------------------------------------------------------------------
# DR Recovery Configuration (SECONDARY only)
# S3_RECOVER_FROM_* env vars - refers to PRIMARY (source) cluster
# -----------------------------------------------------------------------------
# s3_recover_from_region                     = "us-west-2"
# s3_recover_from_bucket                     = ""  # Auto-fetched from primary remote state
# s3_recover_from_encryption_key_secret_name = "dr-secondary-s3-storage-encryption"
# s3_recover_from_encryption_key_secret_key  = "s3-storage-encryption-key"
# s3_recover_from_replace_region             = "us-west-2/us-east-2"
# s3_recover_from_replace_bucket             = "primary-bucket/secondary-bucket"

# -----------------------------------------------------------------------------
# DR Failover Lambda (SECONDARY only)
# Automated operator scaling on primary failure
# -----------------------------------------------------------------------------
# dr_failover_lambda_enabled                      = true
# dr_failover_lambda_target_node_count            = 1
# dr_failover_lambda_timeout                      = 60
# dr_failover_lambda_memory_mb                    = 256
# dr_failover_lambda_log_retention_days           = 7
# dr_failover_lambda_skip_secondary_health_check  = false
# dr_failover_lambda_pre_failover_failure_seconds = 180  # Use 0 for testing only

# -----------------------------------------------------------------------------
# DR Traffic Detector (SECONDARY only)
# Automatic digest scaling based on DNS resolution
# -----------------------------------------------------------------------------
# dr_traffic_detector_enabled = true
# dr_humiocluster_name        = ""  # HumioCluster resource name
# dr_check_interval           = 5   # DNS check interval in seconds
# dr_consecutive_checks       = 3   # Checks required before scaling
# dr_traffic_detector_image   = "bitnami/kubectl:1.32.0"

# =============================================================================
# COMPONENT VERSIONS
# =============================================================================
# Strimzi Kafka
strimzi_operator_version       = "0.45.0"
strimzi_operator_chart_version = "0.45.0"
provision_kafka_servers        = true
kafka_version                  = "4.1.x"
msk_cluster_name               = "logscale-msk" # Only used if provision_kafka_servers=false

# Humio Operator
humio_operator_version       = "0.32.0"
humio_operator_chart_version = "0.32.0"

# Other Components
cm_namespace                     = "cert-manager"
cm_repo                          = "https://charts.jetstack.io"
cm_version                       = "v1.17.1"
alb_controller_version           = "1.13.3"
topo_lvm_chart_version           = "15.6.0"

# =============================================================================
# CERTIFICATE CONFIGURATION
# =============================================================================
logscale_operator_repo = "https://humio.github.io/humio-operator"
issuer_kind            = "ClusterIssuer"
issuer_name            = "letsencrypt-cluster-issuer"
issuer_email           = "admin@example.com"
issuer_private_key     = "letsencrypt-cluster-issuer-key"
ca_server              = "https://acme-v02.api.letsencrypt.org/directory"

# =============================================================================
# RESOURCE NAMING AND TAGS
# =============================================================================
tags = {
  App           = "humio"
  DeployVersion = "1.0.0"
  ManagedBy     = "Terraform"
  Environment   = "production"
}

# =============================================================================
# OPTIONAL: Humio Operator Resource Limits
# =============================================================================
humio_operator_extra_values = {
  "operator.resources.limits.cpu"      = "250m"
  "operator.resources.limits.memory"   = "750Mi"
  "operator.resources.requests.cpu"    = "250m"
  "operator.resources.requests.memory" = "750Mi"
}
