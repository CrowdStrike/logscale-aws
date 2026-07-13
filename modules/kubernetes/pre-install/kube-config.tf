resource "local_sensitive_file" "kubeconfig" {
  content = templatefile("${path.module}/templates/kubeconfig.tpl", {
    cluster_name     = var.cluster_name,
    cluster_endpoint = var.cluster_endpoint,
    cluster_ca       = var.cluster_certificate_authority_data,
    aws_region       = var.aws_region
    aws_profile      = var.aws_profile
  })
  filename        = "${path.root}/kubeconfig-${var.cluster_name}.yaml"
  file_permission = "0600"
}