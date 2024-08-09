
# output "humio_operator_crds" {
#   description = "Manifest of Humio Operator CRD objects"
#   value = {
#     for k, v in kubernetes_manifest.humio_operator_crds :
#     k => v.manifest
#   }
# }


# output "cert_manager_crds" {
#   description = "Manifest of Cert-Manager CRD objects"
#   value = {
#     for k, v in kubernetes_manifest.cert_manager_crds.manifest :
#     k => v.manifest
#   }
# }
