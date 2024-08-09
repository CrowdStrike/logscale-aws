module "vpc" {
  source       = "./modules/aws/vpc"
  name         = var.vpc_name
  vpc_cidr     = var.vpc_cidr
  cluster_name = var.cluster_name
  tags         = merge(var.tags, { "Name" = var.cluster_name })
}

module "msk" {
  source                     = "./modules/aws/msk"
  cluster_name               = var.cluster_name
  msk_number_of_broker_nodes = local.cluster_size_selected["kafka_broker_node_count"]
  broker_node_instance_type  = local.cluster_size_selected["kafka_broker_instance_type"]
  private_subnets            = module.vpc.private_subnets
  msk_sg_id                  = module.vpc.msk_sg_id
  kafka_version              = var.kafka_version
  msk_cluster_name           = var.msk_cluster_name
  msk_node_volume_size       = local.cluster_size_selected["kafka_broker_data_disk_size"]
  tags                       = var.tags
}

module "eks" {
  source                         = "./modules/aws/eks"
  vpc_id                         = module.vpc.vpc_id
  cluster_name                   = var.cluster_name
  cluster_version                = var.cluster_version
  private_subnets                = module.vpc.private_subnets
  intra_subnets                  = module.vpc.intra_subnets
  ami_type                       = var.ami_type
  logscale_node_root_volume_size = local.cluster_size_selected["logscale_digest_root_disk_size"]
  logscale_node_root_volume_type = local.cluster_size_selected["logscale_digest_root_disk_type"]
  logscale_cluster_type          = var.logscale_cluster_type

  logscale_node_desired_capacity = local.cluster_size_selected["logscale_digest_desired_node_count"]
  logscale_node_max_capacity     = local.cluster_size_selected["logscale_digest_max_node_count"]
  logscale_node_min_capacity     = local.cluster_size_selected["logscale_digest_min_node_count"]
  logscale_instance_type         = local.cluster_size_selected["logscale_digest_instance_type"]

  ingress_node_desired_capacity = local.cluster_size_selected["logscale_ingress_desired_node_count"]
  ingress_node_max_capacity     = local.cluster_size_selected["logscale_ingress_max_node_count"]
  ingress_node_min_capacity     = local.cluster_size_selected["logscale_ingress_min_node_count"]
  ingress_instance_type         = local.cluster_size_selected["logscale_ingress_instance_type"]

  ingest_node_desired_capacity   = local.cluster_size_selected["logscale_ingest_desired_node_count"]
  ingest_node_max_capacity       = local.cluster_size_selected["logscale_ingest_max_node_count"]
  ingest_node_min_capacity       = local.cluster_size_selected["logscale_ingest_min_node_count"]
  ingest_instance_type           = local.cluster_size_selected["logscale_ingest_instance_type"]
  logscale_ingest_data_disk_size = local.cluster_size_selected["logscale_ingest_data_disk_size"]
  logscale_ingest_data_disk_type = local.cluster_size_selected["logscale_ingest_data_disk_type"]
  logscale_ingest_root_disk_size = local.cluster_size_selected["logscale_ingest_root_disk_size"]
  logscale_ingest_root_disk_type = local.cluster_size_selected["logscale_ingest_root_disk_type"]

  ui_node_desired_capacity   = local.cluster_size_selected["logscale_ui_desired_node_count"]
  ui_node_max_capacity       = local.cluster_size_selected["logscale_ui_max_node_count"]
  ui_node_min_capacity       = local.cluster_size_selected["logscale_ui_min_node_count"]
  ui_instance_type           = local.cluster_size_selected["logscale_ui_instance_type"]
  logscale_ui_data_disk_size = local.cluster_size_selected["logscale_ui_data_disk_size"]
  logscale_ui_data_disk_type = local.cluster_size_selected["logscale_ui_data_disk_type"]
  logscale_ui_root_disk_size = local.cluster_size_selected["logscale_ui_root_disk_size"]
  logscale_ui_root_disk_type = local.cluster_size_selected["logscale_ui_root_disk_type"]

  zone_name          = var.zone_name
  hostname           = var.hostname
  msk_sg_id          = module.vpc.msk_sg_id
  route53_record_ttl = var.route53_record_ttl
  s3_bucket_prefix   = var.eks_s3_bucket_prefix
  tags               = merge(var.tags, { "Name" = var.cluster_name })
}

module "crds" {
  source                 = "./modules/kubernetes/crds"
  humio_operator_version = var.humio_operator_version
  cluster_endpoint       = module.eks.cluster_endpoint

}

module "logscale" {
  source                             = "./modules/kubernetes/logscale"
  aws_region                         = var.aws_region
  aws_profile                        = var.aws_profile
  cluster_name                       = var.cluster_name
  cluster_endpoint                   = module.eks.cluster_endpoint
  cluster_certificate_authority_data = module.eks.cluster_certificate_authority_data
  ca_server                          = var.ca_server
  humio_operator_chart_version       = var.humio_operator_chart_version
  humio_operator_version             = var.humio_operator_version
  issuer_name                        = var.issuer_name
  issuer_email                       = var.issuer_email
  issuer_kind                        = var.issuer_kind
  issuer_private_key                 = var.issuer_private_key
  logscale_operator_repo             = var.logscale_operator_repo
  logscale_image_version             = var.logscale_image_version
  cm_version                         = var.cm_version
  cm_repo                            = var.cm_repo
  logscale_namespace                 = var.logscale_namespace
  cm_namespace                       = var.cm_namespace
  humio_operator_extra_values        = var.humio_operator_extra_values
  logscale_cluster_type              = var.logscale_cluster_type
  zone_name                          = var.zone_name
  acm_certificate_arn                = module.eks.acm_certificate_arn
  logscale_s3_bucket_id              = module.eks.logscale_s3_bucket_id
  msk_bootstrap_brokers              = module.msk.msk_bootstrap_brokers
  service_account_aws_iam_role_arn   = module.eks.service_account_aws_iam_role_arn
  eks_lb_controller_role_arn         = module.eks.eks_lb_controller_role_arn
  humiocluster_license               = var.humiocluster_license
  zookeeper_connect_string           = module.msk.zookeeper_connect_string
  hostname                           = var.hostname
  external_dns_iam_role_arn          = module.eks.external_dns_iam_role_arn

  # sizing
  logscale_digest_resources       = local.cluster_size_selected["logscale_digest_resources"]
  logscale_digest_node_count      = local.cluster_size_selected["logscale_digest_node_count"]
  logscale_digest_data_disk_size  = local.cluster_size_selected["logscale_digest_data_disk_size"]
  logscale_ingest_resources       = local.cluster_size_selected["logscale_ingest_resources"]
  logscale_ingest_data_disk_size  = local.cluster_size_selected["logscale_ingest_data_disk_size"]
  logscale_ingest_node_count      = local.cluster_size_selected["logscale_ingest_node_count"]
  logscale_ingress_resources      = local.cluster_size_selected["logscale_ingress_resources"]
  logscale_ingress_node_count     = local.cluster_size_selected["logscale_ingress_node_count"]
  logscale_ingress_data_disk_size = local.cluster_size_selected["logscale_ingress_data_disk_size"]
  logscale_ui_resources           = local.cluster_size_selected["logscale_ui_resources"]
  logscale_ui_node_count          = local.cluster_size_selected["logscale_ui_node_count"]
  logscale_ui_data_disk_size      = local.cluster_size_selected["logscale_ui_data_disk_size"]
}
