data "aws_caller_identity" "current" {}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name             = var.cluster_name
  cluster_version          = var.cluster_version
  subnet_ids               = var.private_subnets
  control_plane_subnet_ids = var.intra_subnets

  vpc_id = var.vpc_id

  enable_cluster_creator_admin_permissions = true

  authentication_mode = "API_AND_CONFIG_MAP"

  cluster_endpoint_public_access = var.cluster_endpoint_public_access

  cluster_enabled_log_types = var.cluster_enabled_log_types

  kms_key_administrators = [data.aws_caller_identity.current.arn]

  kms_key_owners = [data.aws_caller_identity.current.arn]

  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent    = true
      before_compute = true
      configuration_values = jsonencode({
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      resolve_conflicts        = "OVERWRITE"
      service_account_role_arn = aws_iam_role.ebs_csi_role.arn
    }
  }

  eks_managed_node_groups = local.eks_managed_node_groups

  tags = var.tags
}
