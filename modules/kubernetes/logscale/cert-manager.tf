# Check if the CRD has been applied
data "kubernetes_resources" "check_cert_manager_crd" {
  api_version    = "apiextensions.k8s.io/v1"
  kind           = "CustomResourceDefinition"
  field_selector = "metadata.name=clusterissuers.cert-manager.io"
}

resource "kubernetes_namespace" "cert_manager" {
  metadata {
    name = var.cm_namespace
  }
}

# Deploy cert-manager helm chart
resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  repository = var.cm_repo
  chart      = "cert-manager"
  namespace  = kubernetes_namespace.cert_manager.metadata[0].name
  version    = var.cm_version

  values = [
    <<-EOT
    ingressShim:
      defaultIssuerName: var.issuer_name
      defaultIssuerKind: var.issuer_kind
    EOT
  ]
  depends_on = [data.kubernetes_resources.check_cert_manager_crd,
    helm_release.aws_lb_controller
  ]
}
