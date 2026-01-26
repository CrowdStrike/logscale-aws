/* Create logscale namespace */
resource "null_resource" "logscale_ns" {
  triggers = {
    namespace_name = var.logscale_namespace
  }

  provisioner "local-exec" {
    command = "kubectl create namespace ${var.logscale_namespace} --dry-run=client -o yaml | kubectl apply -f -"
  }

  provisioner "local-exec" {
    when = destroy
    command = "kubectl delete namespace ${self.triggers.namespace_name} --timeout=60s --ignore-not-found=true"
  }
}
