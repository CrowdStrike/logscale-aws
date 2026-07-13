data "aws_region" "current" {}

# IAM Role for Service Accounts in EKS
data "aws_iam_policy_document" "logscale_bucket_policy" {
  # Allow ListBucket on the local (secondary) bucket
  statement {
    effect = "Allow"

    actions = [
      "s3:ListBucket"
    ]

    resources = [
      "arn:aws:s3:::${module.s3_logs_bucket_logscale.s3_bucket_id}",
    ]
  }

  # Allow object operations on the local (secondary) bucket
  statement {
    effect = "Allow"

    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject"
    ]

    resources = [
      "arn:aws:s3:::${module.s3_logs_bucket_logscale.s3_bucket_id}/*"
    ]
  }


  statement {
    effect = "Allow"

    actions = [
      "kms:GenerateDataKey",
      "kms:Decrypt"
    ]

    resources = [
      "arn:aws:kms:${data.aws_region.current.region}:${data.aws_caller_identity.current.id}:key/*"
    ]
  }
}

resource "aws_iam_policy" "logscale_iam_policy" {
  name_prefix = var.cluster_name
  description = var.logscale_iam_policy_description
  policy      = data.aws_iam_policy_document.logscale_bucket_policy.json
}

resource "aws_iam_role" "role_eks_logscale" {
  name = "logscale-${var.cluster_name}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = "arn:aws:iam::${data.aws_caller_identity.current.id}:oidc-provider/${module.eks.oidc_provider}"
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          # Require the standard IRSA audience
          StringEquals = {
            "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
          }
          # Allow service accounts in the logging namespace matching the Humio operator's
          # naming convention: <humiocluster-name>-humio (e.g., "logscale-humio")
          StringLike = {
            "${module.eks.oidc_provider}:sub" = "system:serviceaccount:logging:*-humio"
          }
        }
      }
    ]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "logscale_policy_attachment" {
  role       = aws_iam_role.role_eks_logscale.name
  policy_arn = aws_iam_policy.logscale_iam_policy.arn
}

# Additional read-only access to the PRIMARY bucket for DR cross-region access
# This allows the secondary cluster to read from the primary cluster's S3 bucket
data "aws_iam_policy_document" "dr_primary_bucket_read" {
  count = var.dr_primary_s3_bucket != null ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["s3:ListBucket"]
    resources = [
      "arn:aws:s3:::${var.dr_primary_s3_bucket}",
    ]
  }

  statement {
    effect  = "Allow"
    actions = ["s3:GetObject"]
    resources = [
      "arn:aws:s3:::${var.dr_primary_s3_bucket}/*"
    ]
  }
}

resource "aws_iam_policy" "dr_primary_bucket_read" {
  count       = var.dr_primary_s3_bucket != null ? 1 : 0
  name_prefix = "logscale-read-${var.cluster_name}-"
  description = "Read-only access to primary S3 bucket for DR recovery"
  policy      = data.aws_iam_policy_document.dr_primary_bucket_read[0].json
}

resource "aws_iam_role_policy_attachment" "logscale_dr_read_attachment" {
  count      = var.dr_primary_s3_bucket != null ? 1 : 0
  role       = aws_iam_role.role_eks_logscale.name
  policy_arn = aws_iam_policy.dr_primary_bucket_read[0].arn
}

# ELB Ingress controller
module "iam_eks_role_lb_controller" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.2"

  name = "EKS_LB_Controller_Role-${var.cluster_name}"

  attach_load_balancer_controller_policy = true

  oidc_providers = {
    one = {
      provider_arn               = "arn:aws:iam::${data.aws_caller_identity.current.id}:oidc-provider/${module.eks.oidc_provider}"
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
  tags = var.tags
}

# External DNS
resource "aws_iam_policy" "external_dns" {
  name        = "AllowExternalDNSUpdates-${var.cluster_name}"
  description = var.external_dns_iam_policy_description
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        "Effect" : "Allow",
        "Action" : [
          "route53:ChangeResourceRecordSets"
        ],
        "Resource" : [
          "arn:aws:route53:::hostedzone/*"
        ]
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "route53:ListHostedZones",
          "route53:ListResourceRecordSets",
          "route53:ListTagsForResource"
        ],
        "Resource" : [
          "*"
        ]
      }
    ]
  })
}

resource "aws_iam_role" "external_dns" {
  name = "External_DNS_${var.cluster_name}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = "arn:aws:iam::${data.aws_caller_identity.current.id}:oidc-provider/${module.eks.oidc_provider}"
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com",
            "${module.eks.oidc_provider}:sub" = "system:serviceaccount:kube-system:external-dns"
          }
        }
      }
    ]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "external_dns_attachment" {
  policy_arn = aws_iam_policy.external_dns.arn
  role       = aws_iam_role.external_dns.name
}

## EBS CSI Driver IAM role ##
resource "aws_iam_role" "ebs_csi_role" {
  name = "AmazonEKS_EBS_CSI_DriverRole_${var.cluster_name}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = "arn:aws:iam::${data.aws_caller_identity.current.id}:oidc-provider/${module.eks.oidc_provider}"
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com",
            "${module.eks.oidc_provider}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          }
        }
      }
    ]
  })
  tags = var.tags
}

data "aws_iam_policy_document" "ebs_policy" {
  statement {
    actions = [
      "ec2:AttachVolume",
      "ec2:CreateSnapshot",
      "ec2:CreateTags",
      "ec2:CreateVolume",
      "ec2:DeleteSnapshot",
      "ec2:DeleteTags",
      "ec2:DeleteVolume",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeInstances",
      "ec2:DescribeSnapshots",
      "ec2:DescribeTags",
      "ec2:DescribeVolumes",
      "ec2:DescribeVolumesModifications",
      "ec2:DetachVolume",
      "ec2:ModifyVolume"
    ]

    effect    = "Allow"
    resources = ["*"]
  }
}

resource "aws_iam_policy" "ebs_policy" {
  name   = "AmazonEKS_EBS_CSI_DriverPolicy-${var.cluster_name}"
  policy = data.aws_iam_policy_document.ebs_policy.json
}

resource "aws_iam_role_policy_attachment" "ebs_policy_attachment" {
  role       = aws_iam_role.ebs_csi_role.name
  policy_arn = aws_iam_policy.ebs_policy.arn
}
