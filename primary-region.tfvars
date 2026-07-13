
tags = {
  App           = "humio"
  DeployVersion = "1.0.0"
  ManagedBy     = "Terraform"
  Environment   = "primary"
  Region        = "eu-central-1"
}

# Workspace validation - ensures this tfvars is used with the correct workspace
expected_workspace = "primary"

aws_region  = "eu-central-1"
aws_profile = "<aws_profile>"
vpc_name    = "logscale-vpc-dr-primary"
vpc_cidr    = "10.0.0.0/16"

cluster_name    = "primary-eu-ls"
cluster_version = "1.33"

ami_type           = "AL2023_x86_64_STANDARD"
logscale_namespace = "logging"
cm_namespace       = "cert-manager"
cm_repo            = "https://charts.jetstack.io"
cm_version         = "v1.17.1"

logscale_operator_repo = "https://humio.github.io/humio-operator"
issuer_kind            = "ClusterIssuer"
issuer_name            = "letsencrypt-cluster-issuer"
issuer_email           = "<mail@domain.com>"
issuer_private_key     = "letsencrypt-cluster-issuer-key"
ca_server              = "https://acme-v02.api.letsencrypt.org/directory"

humio_operator_chart_version     = "0.33.0"
humio_operator_version           = "0.33.0"
logscale_image_version           = "1.210.0"
external_dns_chart_version       = "1.20.0"
alb_controller_version           = "3.2.1"
gateway_api_version              = "v1.5.1"
topo_lvm_chart_version           = "15.7.0"

humiocluster_license = "..."
humio_operator_extra_values = {
  "operator.resources.limits.cpu"      = "250m"
  "operator.resources.limits.memory"   = "750Mi"
  "operator.resources.requests.cpu"    = "250m"
  "operator.resources.requests.memory" = "750Mi"
}
logscale_cluster_size   = "xsmall"
logscale_cluster_type   = "advanced"
provision_kafka_servers = true
kafka_version           = "4.0.0"
msk_cluster_name        = "logscale-msk-dr-primary"
zone_name               = "<subdomain>.<domain>.<tld>"
hostname                = "logscale-dr-eu-primary"
route53_record_ttl      = 60

eks_s3_bucket_prefix = "<s3_bucket_prefix>"
eks_s3_bucket_name   = "<s3_bucket_name>"

strimzi_operator_version       = "0.48.0"
strimzi_operator_chart_version = "0.48.0"

dr = "active"

# DR Cross-region configuration - Grants primary cluster read access to secondary bucket
# This enables the primary cluster to read from the secondary cluster's S3 bucket for DR scenarios
dr_primary_s3_bucket = "<dr_primary_bucket_name>"

# Global DNS configuration for DR failover
manage_global_dns           = true
global_logscale_hostname    = "<hostname_global>"
primary_logscale_hostname   = "<hostname_primary>"
secondary_logscale_hostname = "<hostname_secondary>"

# Extra variables to be passed to the LogScale cluster
# extra_user_logscale_envvars = [
#   {
#     name  = "VAR_NAME"
#     value = ""
#   }
# ]
