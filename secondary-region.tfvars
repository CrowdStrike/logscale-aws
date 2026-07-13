# =============================================================================
# LogScale AWS Terraform Configuration - DR Secondary Cluster
# =============================================================================
# This is the SECONDARY (standby) cluster in a DR pair.
# Key characteristics:
#   - dr="standby" - minimal resource usage in standby mode
#   - Reads from primary cluster's S3 snapshots for data recovery
#   - manage_global_dns=false - primary cluster manages DNS failover
#   - Automated failover via Lambda and traffic detection
# =============================================================================

# =============================================================================
# WORKSPACE VALIDATION
# Must match terraform workspace name - prevents applying wrong config
# =============================================================================
expected_workspace = "secondary"

# =============================================================================
# AWS AUTHENTICATION
# Required for all AWS API operations
# =============================================================================
aws_region  = "eu-west-1"
aws_profile = "<aws_profile>"

# =============================================================================
# NETWORKING
# IMPORTANT: VPC CIDR must be unique from primary cluster
# Primary:   10.0.0.0/16 (eu-central-1)
# Secondary: 10.1.0.0/16 (eu-west-1)
# =============================================================================
vpc_name    = "logscale-vpc-dr-secondary"
vpc_cidr    = "10.1.0.0/16"

# =============================================================================
# RESOURCE NAMING AND TAGS
# =============================================================================
tags = {
  App           = "humio"
  DeployVersion = "1.0.0"
  ManagedBy     = "Terraform"
  Environment   = "secondary"
  Region        = "eu-west-1"
}

# =============================================================================
# EKS CLUSTER CONFIGURATION
# =============================================================================
cluster_name        = "dr-scndary-eu"
cluster_version     = "1.33"
ami_type            = "AL2023_x86_64_STANDARD"
ami_release_version = "1.33.5-20251120"

# =============================================================================
# VERSIONS
# =============================================================================
cm_version                       = "v1.17.1"
external_dns_chart_version       = "1.20.0"
alb_controller_version           = "3.2.1"
gateway_api_version              = "v1.5.1"
topo_lvm_chart_version           = "15.7.0"

# Kafka (Strimzi)
kafka_version                    = "4.0.0"
strimzi_operator_version         = "0.48.0"
strimzi_operator_chart_version   = "0.48.0"

# Humio Operator
humio_operator_chart_version     = "0.33.0"
humio_operator_version           = "0.33.0"
logscale_image_version           = "1.210.0"

# =============================================================================
# CERTIFICATE CONFIGURATION
# =============================================================================
cm_namespace        = "cert-manager"
cm_repo             = "https://charts.jetstack.io"

issuer_kind            = "ClusterIssuer"
issuer_name            = "letsencrypt-cluster-issuer"
issuer_email           = "<mail@domain.com>"
issuer_private_key     = "letsencrypt-cluster-issuer-key"
ca_server              = "https://acme-v02.api.letsencrypt.org/directory"


# =============================================================================
# LOGSCALE CONFIGURATION
# =============================================================================
logscale_namespace  = "logging"
logscale_operator_repo = "https://humio.github.io/humio-operator"
# License Key (JWT format)
humiocluster_license = "..."

# =============================================================================
# OPTIONAL: Humio Operator Resource Limits
# =============================================================================
humio_operator_extra_values = {
  "operator.resources.limits.cpu"      = "250m"
  "operator.resources.limits.memory"   = "750Mi"
  "operator.resources.requests.cpu"    = "250m"
  "operator.resources.requests.memory" = "750Mi"
}

logscale_cluster_size   = "xsmall"
logscale_cluster_type   = "advanced"

# =============================================================================
# KAFKA CONFIGURATION
# =============================================================================
# Strimzi Kafka (embedded in cluster)
provision_kafka_servers = true
msk_cluster_name        = "logscale-msk-dr-secondary" # Only used if provision_kafka_servers=false

# =============================================================================
# DNS CONFIGURATION
# =============================================================================
zone_name               = "<subdomain>.<domain>.<tld>" # Route53
hostname                = "<hostname_secondary>"       # Cluster-specific hostname
route53_record_ttl      = 60

# =============================================================================
# S3 STORAGE
# =============================================================================
eks_s3_bucket_name   =  "<dr_secondary_bucket_name>"

# =============================================================================
# DR CONFIGURATION
# =============================================================================
# DR Mode: "standby" = secondary cluster with minimal resources
# - Only 1 digest pod runs (nodePools=null)
# - Reads from primary's S3 snapshots for data recovery
# - Automated failover capabilities enabled
dr = "standby"

# Two-Phase DR Promotion Support
# For STANDBY clusters: MUST be false to route traffic through single digest pod
# For ACTIVE clusters during promotion:
#   Phase 1: Set dr="active" and dr_use_dedicated_routing=false (zero downtime)
#   Phase 2: Set dr_use_dedicated_routing=true after UI/Ingest pods are ready
dr_use_dedicated_routing = false

# Pre-known peer bucket for DR read (primary bucket)
dr_primary_s3_bucket = "<dr_primary_bucket_name>"

# -----------------------------------------------------------------------------
# Remote State (SECONDARY only)
# Used to fetch encryption key, health check IDs, and S3 bucket info from primary
# CRITICAL: workspace must match the primary's Terraform workspace name
# CRITICAL: key must match the primary's backend-config key value exactly
# -----------------------------------------------------------------------------
primary_remote_state_config = {
  backend   = "s3"
  workspace = "primary" # Primary cluster is deployed in the default workspace
  config = {
    bucket = "<remote_state_bucket>"
    key    = "env:/logscale-aws-eks"
    # key    = "terraform.tfstate"

    region  = "eu-central-1"
    profile = "<aws_profile>"
  }
}

# Do NOT set existing_s3_encryption_key - it will be pulled from primary's remote state
# Once the primary workspace outputs are populated (via terraform apply/refresh),
# the secondary will automatically use the same encryption key via local.effective_s3_encryption_key

# -----------------------------------------------------------------------------
# DR Recovery Configuration - Required for failover
# IMPORTANT: S3_RECOVER_FROM_* variables specify WHERE WE ARE RECOVERING FROM (the PRIMARY cluster)
# S3_RECOVER_FROM_REGION should be the PRIMARY cluster's region (eu-central-1) - where the snapshots are
# S3_RECOVER_FROM_BUCKET should be the PRIMARY cluster's bucket - where LogScale will find snapshots to recover from
# The encryption key is from the primary cluster (same value) but stored in the secondary cluster's secret
# -----------------------------------------------------------------------------
s3_recover_from_region = "eu-central-1"
s3_recover_from_bucket =  "<dr_primary_bucket_name>"
# The secret name will be "dr-secondary-s3-storage-encryption" (created by pre-install module with primary's key value)
s3_recover_from_encryption_key_secret_name = "dr-secondary-s3-storage-encryption"
s3_recover_from_encryption_key_secret_key  = "s3-storage-encryption-key"

# Advanced DR options - Region replacement configuration
# Format: <primary-region>/<secondary-region>
s3_recover_from_replace_region = "eu-central-1/eu-west-1"
# s3_recover_from_replace_bucket format: <primary-bucket>/<secondary-bucket>
# Leave this commented out to allow Terraform to automatically construct it from remote state
# When remote state is configured, Terraform will automatically use:
# format("%s/%s", primary_s3_bucket_from_remote_state, current_secondary_s3_bucket)
# Only uncomment and set manually if not using remote state or need to override
# s3_recover_from_replace_bucket = "<logscale-dr-primary-s3-bucket-name>/<logscale-dr-secondary-s3-bucket-name>"

# Global DNS configuration for DR failover
# Note: manage_global_dns is false because the primary cluster manages the global DNS resources
# This avoids duplicate Route53 records and health checks
manage_global_dns           = false
global_logscale_hostname    = "<hostname_global>"
primary_logscale_hostname   = "<hostname_primary>"
secondary_logscale_hostname = "<hostname_secondary>"

# DR Traffic Detector Configuration
# Automatically scales digest nodeCount from 0 to 1 when DNS failover is detected
# Note: Now scales base digest nodeCount (.spec.nodeCount), not a nodepool
dr_traffic_detector_enabled = true
dr_humiocluster_name        = "dr-logscale"
dr_check_interval           = 5
dr_consecutive_checks       = 3

# DR Failover Lambda Configuration
# Enables CloudWatch alarm + Lambda function to scale humio-operator on failover
dr_failover_lambda_enabled = true

# Allow DR Lambda simulations to skip secondary health check gating (standby starts at 0 nodes)
dr_failover_lambda_skip_secondary_health_check = true

# Immediate failover for testing (set to 180 for production)
dr_failover_lambda_pre_failover_failure_seconds = 0

# DR Cloud Function Configuration (standby automation)
dr_failover_lambda_target_node_count = 1
dr_failover_lambda_timeout           = 300
dr_failover_lambda_memory_mb         = 256

# Extra variables to be passed to the LogScale cluster
# extra_user_logscale_envvars = [
#   {
#     name  = "VAR_NAME"
#     value = ""
#   }
# ]