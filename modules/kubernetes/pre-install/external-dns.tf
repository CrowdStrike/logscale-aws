resource "helm_release" "external_dns" {
  name       = "external-dns"
  repository = var.external_dns_repository
  chart      = "external-dns"
  namespace  = "kube-system"
  version    = var.external_dns_chart_version

  set {
    name  = "provider"
    value = "aws"
  }

  set {
    name  = "aws.region"
    value = var.aws_region
  }

  set {
    name  = "aws.zoneType"
    value = "public"
  }

  set {
    name  = "sources[0]"
    value = "gateway-httproute"
  }

  set {
    name  = "rbac.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "external-dns"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = var.external_dns_iam_role_arn
  }

  # Only process ingresses that have our ExternalDNS hostname annotation.
  # This excludes cert-manager ACME HTTP-01 solver ingresses, which would
  # otherwise cause ExternalDNS to create A records for the global DR hostname
  # and conflict with the Route53 failover CNAME records managed by global-dns.
  set {
    name  = "annotationFilter"
    value = "external-dns.alpha.kubernetes.io/hostname"
  }
}