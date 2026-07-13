module "vpc" {
  source       = "./modules/aws/vpc"
  name         = var.vpc_name
  vpc_cidr     = var.vpc_cidr
  cluster_name = var.cluster_name
  tags         = merge(var.tags, { "Name" = var.cluster_name })

  # Configure the kubernetes provider    
  providers = {
    aws = aws
  }
}

module "msk" {
  source                     = "./modules/aws/msk"
  count                      = !var.provision_kafka_servers && var.dr != "standby" ? 1 : 0
  cluster_name               = var.cluster_name
  msk_number_of_broker_nodes = local.cluster_size["kafka_broker_node_count"]
  broker_node_instance_type  = local.cluster_size["kafka_broker_instance_type"]
  private_subnets            = module.vpc.private_subnets
  msk_sg_id                  = module.vpc.msk_sg_id
  kafka_version              = var.kafka_version
  msk_cluster_name           = var.msk_cluster_name
  msk_node_volume_size       = tonumber(regex("^([0-9]+)", local.cluster_size["kafka_broker_data_disk_size"])[0])
  tags                       = var.tags

  # Configure the kubernetes provider
  providers = {
    aws = aws
  }
}

module "eks" {
  source                = "./modules/aws/eks"
  vpc_id                = module.vpc.vpc_id
  cluster_name          = var.cluster_name
  cluster_version       = var.cluster_version
  private_subnets       = module.vpc.private_subnets
  intra_subnets         = module.vpc.intra_subnets
  ami_type              = var.ami_type
  ami_release_version   = var.ami_release_version
  logscale_cluster_type = var.logscale_cluster_type

  provision_kafka_servers = var.provision_kafka_servers

  kafka_broker_node_count     = local.cluster_size["kafka_broker_node_count"]
  kafka_broker_min_node_count = local.cluster_size["kafka_broker_min_node_count"]
  kafka_broker_max_node_count = local.cluster_size["kafka_broker_max_node_count"]
  kafka_broker_instance_type  = substr(local.cluster_size["kafka_broker_instance_type"], 6, -1)

  logscale_node_desired_capacity = local.cluster_size["logscale_digest_desired_node_count"]
  logscale_node_max_capacity     = local.cluster_size["logscale_digest_max_node_count"]
  logscale_node_min_capacity     = local.cluster_size["logscale_digest_min_node_count"]
  logscale_instance_type         = local.cluster_size["logscale_digest_instance_type"]

  ingress_node_desired_capacity = local.cluster_size["logscale_ingress_desired_node_count"]
  ingress_node_max_capacity     = local.cluster_size["logscale_ingress_max_node_count"]
  ingress_node_min_capacity     = local.cluster_size["logscale_ingress_min_node_count"]
  ingress_instance_type         = local.cluster_size["logscale_ingress_instance_type"]

  ingest_node_desired_capacity = local.cluster_size["logscale_ingest_desired_node_count"]
  ingest_node_max_capacity     = local.cluster_size["logscale_ingest_max_node_count"]
  ingest_node_min_capacity     = local.cluster_size["logscale_ingest_min_node_count"]
  ingest_instance_type         = local.cluster_size["logscale_ingest_instance_type"]

  ui_node_desired_capacity = local.cluster_size["logscale_ui_desired_node_count"]
  ui_node_max_capacity     = local.cluster_size["logscale_ui_max_node_count"]
  ui_node_min_capacity     = local.cluster_size["logscale_ui_min_node_count"]
  ui_instance_type         = local.cluster_size["logscale_ui_instance_type"]

  kafka_broker_data_disk_type    = local.cluster_size["kafka_broker_data_disk_type"]
  logscale_node_root_volume_type = local.cluster_size["logscale_digest_root_disk_type"]
  logscale_ingest_data_disk_type = local.cluster_size["logscale_ingest_data_disk_type"]
  logscale_ingest_root_disk_type = local.cluster_size["logscale_ingest_root_disk_type"]
  logscale_ui_data_disk_type     = local.cluster_size["logscale_ui_data_disk_type"]
  logscale_ui_root_disk_type     = local.cluster_size["logscale_ui_root_disk_type"]

  kafka_broker_data_disk_size    = tonumber(regex("^([0-9]+)", local.cluster_size["kafka_broker_data_disk_size"])[0])
  logscale_node_root_volume_size = tonumber(regex("^([0-9]+)", local.cluster_size["logscale_digest_root_disk_size"])[0])
  logscale_ingest_data_disk_size = tonumber(regex("^([0-9]+)", local.cluster_size["logscale_ingest_data_disk_size"])[0])
  logscale_ingest_root_disk_size = tonumber(regex("^([0-9]+)", local.cluster_size["logscale_ingest_root_disk_size"])[0])
  logscale_ui_data_disk_size     = tonumber(regex("^([0-9]+)", local.cluster_size["logscale_ui_data_disk_size"])[0])
  logscale_ui_root_disk_size     = tonumber(regex("^([0-9]+)", local.cluster_size["logscale_ui_root_disk_size"])[0])

  zone_name                = var.zone_name
  hostname                 = var.hostname
  msk_sg_id                = module.vpc.msk_sg_id
  route53_record_ttl       = var.route53_record_ttl
  global_logscale_hostname = var.global_logscale_hostname
  s3_bucket_prefix         = var.eks_s3_bucket_prefix
  s3_bucket_name           = var.eks_s3_bucket_name
  dr                       = var.dr
  dr_primary_s3_bucket     = local.effective_dr_peer_s3_bucket
  tags                     = merge(var.tags, { "Name" = var.cluster_name, "dr" = var.dr })

  # Configure the kubernetes provider    
  providers = {
    aws = aws
  }
}

module "pre-install" {
  source = "./modules/kubernetes/pre-install"

  aws_region         = var.aws_region
  aws_profile        = var.aws_profile
  zone_name          = var.zone_name
  hostname           = var.hostname
  logscale_namespace = var.logscale_namespace

  cluster_name                       = var.cluster_name
  cluster_endpoint                   = module.eks.cluster_endpoint
  cluster_certificate_authority_data = module.eks.cluster_certificate_authority_data

  service_account_aws_iam_role_arn = module.eks.service_account_aws_iam_role_arn
  external_dns_iam_role_arn        = module.eks.external_dns_iam_role_arn
  eks_lb_controller_role_arn       = module.eks.eks_lb_controller_role_arn

  external_dns_chart_version = var.external_dns_chart_version
  alb_controller_version     = var.alb_controller_version
  acm_certificate_arn        = module.eks.acm_certificate_arn

  kubeconfig_filepath        = local.kubeconfig_filepath
  existing_s3_encryption_key = local.effective_s3_encryption_key
  dr                         = var.dr

  # DR traffic detector configuration
  dr_traffic_detector_enabled = var.dr_traffic_detector_enabled
  dr_global_dns               = var.dr_global_dns != "" ? var.dr_global_dns : local.dr_global_dns_default
  dr_primary_dns              = var.dr_primary_dns != "" ? var.dr_primary_dns : local.dr_primary_dns_default
  dr_secondary_dns            = var.dr_secondary_dns != "" ? var.dr_secondary_dns : local.dr_secondary_dns_default
  dr_humiocluster_name        = var.dr_humiocluster_name
  dr_check_interval           = var.dr_check_interval
  dr_consecutive_checks       = var.dr_consecutive_checks
  dr_traffic_detector_image   = var.dr_traffic_detector_image

  # Configure the kubernetes provider    
  providers = {
    kubernetes = kubernetes
    helm       = helm
    random     = random
  }
}

module "logscale" {
  source = "git::https://github.com/CrowdStrike/logscale-kubernetes"

  providers = {
    kubernetes = kubernetes
    helm       = helm
  }

  k8s_cluster_name    = var.cluster_name
  k8s_cluster_context = var.cluster_name

  topo_lvm_chart_version           = var.topo_lvm_chart_version

  # kafka
  # In DR standby mode, don't provision Kafka; use MSK if available or empty string as placeholder
  byo_kafka_connection_string    = var.provision_kafka_servers ? "" : (var.dr == "standby" ? "" : module.msk[0].msk_bootstrap_brokers)
  provision_kafka_servers        = var.provision_kafka_servers
  strimzi_operator_version       = var.strimzi_operator_version
  strimzi_operator_chart_version = var.strimzi_operator_chart_version

  # cert manager
  cm_version                      = var.cm_version
  cm_repo                         = var.cm_repo
  cm_namespace                    = var.cm_namespace
  cert_ca_server                  = var.ca_server
  cert_issuer_name                = var.issuer_name
  cert_issuer_email               = var.issuer_email
  cert_issuer_kind                = var.issuer_kind
  cert_issuer_private_key         = var.issuer_private_key
  use_own_certificate_for_ingress = var.use_own_certificate_for_ingress

  # logscale
  logscale_cluster_size        = var.logscale_cluster_size
  logscale_cluster_type        = var.logscale_cluster_type
  logscale_license             = var.humiocluster_license
  logscale_public_fqdn         = "${var.hostname}.${var.zone_name}"
  k8s_namespace_prefix         = var.logscale_namespace
  logscale_image_version       = var.logscale_image_version
  gateway_api_version          = var.gateway_api_version
  humio_operator_chart_version = var.humio_operator_chart_version
  humio_operator_version       = var.humio_operator_version
  humio_operator_extra_values  = var.humio_operator_extra_values

  node_group_definitions = local.cluster_size

  dr                       = var.dr
  dr_use_dedicated_routing = var.dr_use_dedicated_routing

  user_logscale_envvars = concat(local.logscale_envvars, var.extra_user_logscale_envvars)

  extra_humio_cluster_spec = merge(
    {
      humioServiceAccountAnnotations = {
        "eks.amazonaws.com/role-arn" = module.eks.service_account_aws_iam_role_arn
      }
    },
    # DR: Null out nodePools for standby to avoid humio-operator reconciliation loop.
    # Standby clusters don't have UI/ingest node groups, but the shared module still
    # generates nodePool specs with nodeCount=0. The operator interprets these as
    # stale pool status entries, cleaning them up each cycle and never creating the
    # digest pod.
    #
    # During two-phase promotion, Phase 1 (dr="active", dr_use_dedicated_routing=false)
    # restores nodePools so UI/Ingest pods begin scaling up while the generic CIP
    # selector routes all traffic to the existing digest pod. Phase 2 then switches
    # to pool-specific selectors once those pods are ready.
    #
    # IMPORTANT: nodePools must NOT be tied to dr_use_dedicated_routing. Nulling
    # nodePools during Phase 1 causes a 503 outage in Phase 2 because the selector
    # switch and nodePools restore happen in the same apply -- the selectors update
    # instantly but pods take minutes to start, leaving zero Endpoints on the
    # ClusterIP services.
    var.dr == "standby" ? { nodePools = null } : {}
  )

  gateway_controller_name = "gateway.k8s.aws/alb"
  gateway_parameters_ref  = {
    kind      = "LoadBalancerConfiguration"
    # name      = module.pre-install.alb_config_name
    # namespace = module.pre-install.alb_config_namespace
    name      = kubernetes_manifest.alb-config.manifest.metadata.name
    namespace = kubernetes_manifest.alb-config.manifest.metadata.namespace
    group     = "gateway.k8s.aws"
  }

  # When a global DR hostname is configured, add it to the ingress host rules so the ALB
  # accepts requests for the global FQDN. DNS for this hostname is managed separately by
  # the global-dns module (Route53 failover CNAME), not by external-dns. The
  # ingress-hostname-source=annotation-only annotation ensures ExternalDNS only creates
  # records for the cluster-specific hostname listed in the hostname annotation below.
  ingress_extra_hostnames = var.global_logscale_hostname != "" ? ["${var.global_logscale_hostname}.${var.zone_name}"] : []
  extra_gateway_annotations = {
    "external-dns.alpha.kubernetes.io/alias"                   = "true"
    "external-dns.alpha.kubernetes.io/ttl"                     = "300"
    "external-dns.alpha.kubernetes.io/hostname"              = "${var.hostname}.${var.zone_name}"
  }
}

module "global-dns" {
  source = "./modules/aws/global-dns"

  zone_name                   = var.zone_name
  route53_record_ttl          = var.route53_record_ttl
  manage_global_dns           = var.manage_global_dns
  global_logscale_hostname    = var.global_logscale_hostname
  primary_logscale_hostname   = var.primary_logscale_hostname
  secondary_logscale_hostname = var.secondary_logscale_hostname
  dr                          = var.dr
}

module "dr-failover-lambda" {
  count = var.dr_failover_lambda_enabled && var.dr == "standby" ? 1 : 0

  source = "./modules/aws/dr-failover-lambda"

  enabled                      = true
  name_prefix                  = "${var.cluster_name}-dr-failover"
  primary_health_check_id      = local.final_primary_health_check_id
  primary_health_check_fqdn    = "${var.primary_logscale_hostname}.${var.zone_name}"
  secondary_health_check_id    = local.final_secondary_health_check_id
  cluster_name                 = var.cluster_name
  cluster_region               = var.aws_region
  cluster_namespace            = var.logscale_namespace
  operator_target_replicas     = var.dr_failover_lambda_target_node_count
  lambda_timeout_seconds       = var.dr_failover_lambda_timeout
  lambda_memory_mb             = var.dr_failover_lambda_memory_mb
  lambda_runtime               = var.lambda_runtime
  log_retention_days           = var.dr_failover_lambda_log_retention_days
  skip_secondary_health_check  = var.dr_failover_lambda_skip_secondary_health_check
  pre_failover_failure_seconds = var.dr_failover_lambda_pre_failover_failure_seconds
  humiocluster_name            = module.logscale.cluster_name_prefix
  tags                         = merge(var.tags, { "Name" = var.cluster_name, "dr" = var.dr })

  providers = {
    aws                = aws
    aws.route53_region = aws.us_east_1
  }

  # Ensure ALB is created before DR lambda resources
  depends_on = [module.logscale]
}
