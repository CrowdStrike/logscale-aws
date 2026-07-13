/* Create logscale namespace */
resource "kubernetes_namespace_v1" "logscale" {
  metadata {
    name = var.logscale_namespace
  }
}