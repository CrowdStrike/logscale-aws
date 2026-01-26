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
  count                      = var.provision_kafka_servers ? 0 : 1
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
  source                         = "./modules/aws/eks"
  vpc_id                         = module.vpc.vpc_id
  cluster_name                   = var.cluster_name
  cluster_version                = var.cluster_version
  private_subnets                = module.vpc.private_subnets
  intra_subnets                  = module.vpc.intra_subnets
  ami_type                       = var.ami_type
  logscale_cluster_type          = var.logscale_cluster_type

  provision_kafka_servers     = var.provision_kafka_servers

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

  ingest_node_desired_capacity   = local.cluster_size["logscale_ingest_desired_node_count"]
  ingest_node_max_capacity       = local.cluster_size["logscale_ingest_max_node_count"]
  ingest_node_min_capacity       = local.cluster_size["logscale_ingest_min_node_count"]
  ingest_instance_type           = local.cluster_size["logscale_ingest_instance_type"]
  
  ui_node_desired_capacity   = local.cluster_size["logscale_ui_desired_node_count"]
  ui_node_max_capacity       = local.cluster_size["logscale_ui_max_node_count"]
  ui_node_min_capacity       = local.cluster_size["logscale_ui_min_node_count"]
  ui_instance_type           = local.cluster_size["logscale_ui_instance_type"]
  
  kafka_broker_data_disk_type = local.cluster_size["kafka_broker_data_disk_type"]
  logscale_node_root_volume_type = local.cluster_size["logscale_digest_root_disk_type"]
  logscale_ingest_data_disk_type = local.cluster_size["logscale_ingest_data_disk_type"]
  logscale_ingest_root_disk_type = local.cluster_size["logscale_ingest_root_disk_type"]
  logscale_ui_data_disk_type = local.cluster_size["logscale_ui_data_disk_type"]
  logscale_ui_root_disk_type = local.cluster_size["logscale_ui_root_disk_type"]

  kafka_broker_data_disk_size = tonumber(regex("^([0-9]+)", local.cluster_size["kafka_broker_data_disk_size"])[0])
  logscale_node_root_volume_size = tonumber(regex("^([0-9]+)", local.cluster_size["logscale_digest_root_disk_size"])[0])
  logscale_ingest_data_disk_size = tonumber(regex("^([0-9]+)", local.cluster_size["logscale_ingest_data_disk_size"])[0])
  logscale_ingest_root_disk_size = tonumber(regex("^([0-9]+)", local.cluster_size["logscale_ingest_root_disk_size"])[0])
  logscale_ui_data_disk_size = tonumber(regex("^([0-9]+)", local.cluster_size["logscale_ui_data_disk_size"])[0])
  logscale_ui_root_disk_size = tonumber(regex("^([0-9]+)", local.cluster_size["logscale_ui_root_disk_size"])[0])

  zone_name          = var.zone_name
  hostname           = var.hostname
  msk_sg_id          = module.vpc.msk_sg_id
  route53_record_ttl = var.route53_record_ttl
  s3_bucket_prefix   = var.eks_s3_bucket_prefix
  tags               = merge(var.tags, { "Name" = var.cluster_name })

  # Configure the kubernetes provider    
  providers = {
    aws = aws
  }
}

module "pre-install" {
  source                             = "./modules/kubernetes/pre-install"

  aws_region                         = var.aws_region
  aws_profile                        = var.aws_profile
  zone_name                          = var.zone_name
  hostname                           = var.hostname
  logscale_namespace                 = var.logscale_namespace

  cluster_name                       = var.cluster_name
  cluster_endpoint                   = module.eks.cluster_endpoint
  cluster_certificate_authority_data = module.eks.cluster_certificate_authority_data

  service_account_aws_iam_role_arn   = module.eks.service_account_aws_iam_role_arn
  external_dns_iam_role_arn          = module.eks.external_dns_iam_role_arn
  eks_lb_controller_role_arn         = module.eks.eks_lb_controller_role_arn

  alb_controller_version             = var.alb_controller_version

  kubeconfig_filepath                = local.kubeconfig_filepath

  # Configure the kubernetes provider    
  providers = {
    kubernetes = kubernetes
    helm = helm
    random = random
  }
}

module "logscale" {
  source                             = "git::https://github.com/CrowdStrike/logscale-kubernetes"

  k8s_config_path                    = local.kubeconfig_filepath
  k8s_cluster_context                = var.cluster_name

  topo_lvm_chart_version             = var.topo_lvm_chart_version
  nginx_ingress_helm_chart_version   = var.nginx_ingress_helm_chart_version

  # kafka
  byo_kafka_connection_string        = var.provision_kafka_servers ? "" : module.msk.msk_bootstrap_brokers
  provision_kafka_servers            = var.provision_kafka_servers
  strimzi_operator_version           = var.strimzi_operator_version

  # cert manager
  cm_version                         = var.cm_version
  cm_repo                            = var.cm_repo
  cm_namespace                       = var.cm_namespace
  cert_ca_server                     = var.ca_server
  cert_issuer_name                   = var.issuer_name
  cert_issuer_email                  = var.issuer_email
  cert_issuer_kind                   = var.issuer_kind
  cert_issuer_private_key            = var.issuer_private_key
  use_own_certificate_for_ingress    = var.use_own_certificate_for_ingress

  # logscale
  logscale_cluster_size              = var.logscale_cluster_size
  logscale_cluster_type              = var.logscale_cluster_type
  logscale_license                   = var.humiocluster_license
  logscale_public_fqdn               = "${var.hostname}.${var.zone_name}"
  k8s_namespace_prefix               = var.logscale_namespace
  logscale_image_version             = var.logscale_image_version
  humio_operator_chart_version       = var.humio_operator_chart_version
  humio_operator_version             = var.humio_operator_version
  humio_operator_extra_values        = var.humio_operator_extra_values

  node_group_definitions         = local.cluster_size

  user_logscale_envvars = concat([
    {
      "name"  = "INGEST_FEED_AWS_ROLE_ARN"
      "value" = module.eks.service_account_aws_iam_role_arn
    },
    {
      "name"  = "S3_STORAGE_BUCKET"
      "value" = module.eks.logscale_s3_bucket_id
    },
    {
      "name"  = "S3_STORAGE_REGION"
      "value" = var.aws_region
    },
    {
      "name" = "S3_STORAGE_ENCRYPTION_KEY"
      "valueFrom" = {
        "secretKeyRef" = {
          "key"  = "s3-storage-encryption-key"
          "name" = module.pre-install.s3_storage_encryption_key_k8s_secret_name
        }
      }
    },
    {
      "name"  = "S3_STORAGE_PREFERRED_COPY_SOURCE"
      "value" = "true"
    },
  ], var.extra_user_logscale_envvars)

  extra_humio_cluster_spec = {
    humioServiceAccountAnnotations = {
      "eks.amazonaws.com/role-arn" = module.eks.service_account_aws_iam_role_arn
    }
  } 

  ingress_class_name = "alb"
  extra_nginx_annotations = {
    "alb.ingress.kubernetes.io/scheme"                       = "internet-facing"
    "alb.ingress.kubernetes.io/listen-ports"                 = jsonencode([{ HTTPS = 443 }])
    "alb.ingress.kubernetes.io/backend-protocol"             = "HTTPS"
    "alb.ingress.kubernetes.io/certificate-arn"              = module.eks.acm_certificate_arn
    "alb.ingress.kubernetes.io/target-type"                  = "ip"
    "alb.ingress.kubernetes.io/healthcheck-path"             = "/api/v1/status"
    "alb.ingress.kubernetes.io/healthcheck-interval-seconds" = "15"
    "alb.ingress.kubernetes.io/healthcheck-timeout-seconds"  = "10"
    "alb.ingress.kubernetes.io/healthy-threshold-count"      = "2"
    "alb.ingress.kubernetes.io/unhealthy-threshold-count"    = "3"
    "alb.ingress.kubernetes.io/healthcheck-protocol"         = "HTTPS"
    "external-dns.alpha.kubernetes.io/hostname"              = "${var.hostname}.${var.zone_name}"
    "external-dns.alpha.kubernetes.io/alias"                 = "true"
    "external-dns.alpha.kubernetes.io/ttl"                   = "300"
  }
}
