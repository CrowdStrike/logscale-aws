locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  # Calculate private subnets
  private_subnets = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 4, k)]
  #subnetwork_proxy_cidrs = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 4, k + 6)]
  public_subnets = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 48)]
  intra_subnets  = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 52)]

}

data "aws_availability_zones" "available" {}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.8"

  name = var.name
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets
  intra_subnets   = local.intra_subnets

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  create_database_subnet_group = true

  public_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
    Name                                        = "logscale-${var.cluster_name}-public"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
    Name                                        = "logscale-${var.cluster_name}-private"
  }

  intra_subnet_tags = {
    Name = "logscale-${var.cluster_name}-intra"
  }

  tags = var.tags
}



resource "aws_security_group" "allow_internal_vpc" {
  name        = "${module.vpc.name}-allow-internal"
  description = "Allow internal traffic within the VPC"
  vpc_id      = module.vpc.vpc_id

  # Allow ICMP
  ingress {
    description = "Allows incoming ICMP traffic within the internal VPC"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = [var.vpc_cidr]
  }

  # Allow TCP ports 80 to 65535
  ingress {
    description = "Allows incoming TCP traffic within the internal VPC"
    from_port   = 80
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # Allow UDP ports 80 to 65535
  ingress {
    description = "Allows incoming UDP traffic within the internal VPC"
    from_port   = 80
    to_port     = 65535
    protocol    = "udp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Allows outgoing traffic within the internal VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { "Name" = "${module.vpc.name}-allow-internal" })

}

module "security_group_msk" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = var.msk_sg
  description = "Security group for ${var.msk_sg}"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks = module.vpc.private_subnets_cidr_blocks
  ingress_rules = [
    "kafka-broker-tcp",
    "kafka-broker-tls-tcp"
  ]

  tags = var.tags
}
