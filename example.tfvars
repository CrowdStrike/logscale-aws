tags = {
  App           = "humio"
  DeployVersion = "1.0.0"
  ManagedBy     = "Terraform"
}

aws_region  = "eu-central-1"
aws_profile = "logscale-aws"
vpc_name    = "logscale-vpc"
vpc_cidr    = "10.0.0.0/16"

cluster_name           = "logscale-eks"
cluster_version        = "1.34"

ami_type                     = "AL2023_x86_64_STANDARD"
logscale_namespace           = "logscale"
cm_namespace                 = "cert-manager"
cm_repo                      = "https://charts.jetstack.io"
cm_version                   = "v1.19.2"

logscale_operator_repo       = "https://humio.github.io/humio-operator"
ca_server                    = "https://acme-v02.api.letsencrypt.org/directory"
issuer_kind                  = "ClusterIssuer"
issuer_name                  = "letsencrypt-cluster-issuer"
issuer_private_key           = "letsencrypt-cluster-issuer-key"
issuer_email                 = "issuer@email.com" # Change this

humiocluster_license         = "..." # Change this

humio_operator_chart_version     = "0.33.0"
humio_operator_version           = "0.33.0"
logscale_image_version           = "1.219.0"
alb_controller_version           = "1.17.1"
nginx_ingress_helm_chart_version = "4.14.1"
topo_lvm_chart_version           = "15.9.0"

humio_operator_extra_values = {
  "operator.resources.limits.cpu"      = "250m"
  "operator.resources.limits.memory"   = "750Mi"
  "operator.resources.requests.cpu"    = "250m"
  "operator.resources.requests.memory" = "750Mi"
}
logscale_cluster_size   = "xsmall"
logscale_cluster_type   = "basic"
provision_kafka_servers = true
kafka_version           = "3.9.x"
msk_cluster_name        = "logscale-msk"
zone_name               = "subdomain.domain.tld" # Change this
hostname                = "logscale"
route53_record_ttl      = 60

eks_s3_bucket_prefix = "logscale-s3"

strimzi_operator_version        = "0.49.1"
strimzi_operator_chart_version  = "0.49.1"