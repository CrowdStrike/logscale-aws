# Topo LVM Controller Install
resource "helm_release" "topo_lvm_sc" {
  name             = "topo-lvm-sc"
  repository       = "https://topolvm.github.io/topolvm"
  chart            = "topolvm"
  namespace        = "kube-system"
  create_namespace = false
  wait             = "false"
  version          = "15.0.0"

  values = [
    file(join("/", [path.module, "helm_values", "topo_lvm_sc.yaml"]))
  ]

  depends_on = [
    kubernetes_manifest.letsencrypt_cluster_issuer,
    helm_release.cert_manager
  ]
}
