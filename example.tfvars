tags = {
  App           = "humio"
  DeployVersion = "0.1.0"
  ManagedBy     = "Terraform"
}

aws_region  = "us-west-2"
aws_profile = "logscale-aws"
vpc_name    = "logscale-eks-vpc"
vpc_cidr    = "10.0.0.0/16"

cluster_name    = "humiocluster"
cluster_version = "1.30"


ami_type                     = "AL2_x86_64"
logscale_namespace           = "logging"
cm_namespace                 = "cert-manager"
cm_repo                      = "https://charts.jetstack.io"
cm_version                   = "v1.15.1"
logscale_operator_repo       = "https://humio.github.io/humio-operator"
issuer_kind                  = "ClusterIssuer"
issuer_name                  = "letsencrypt-cluster-issuer"
issuer_email                 = ""
issuer_private_key           = "letsencrypt-cluster-issuer-key"
ca_server                    = "https://acme-v02.api.letsencrypt.org/directory"
humio_operator_chart_version = "0.22.0"
humio_operator_version       = "0.22.0"
logscale_image_version       = "1.142.1"
humio_operator_extra_values = {
  "operator.resources.limits.cpu"      = "250m"
  "operator.resources.limits.memory"   = "750Mi"
  "operator.resources.requests.cpu"    = "250m"
  "operator.resources.requests.memory" = "750Mi"
}
logscale_cluster_size = "xsmall"
logscale_cluster_type = "internal-ingest"
kafka_version         = "3.5.1"
msk_cluster_name      = "msk-cluster"
zone_name             = ""  # your Route53 zone name
hostname              = "awstest"
route53_record_ttl    = 60
