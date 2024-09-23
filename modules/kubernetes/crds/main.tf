#Cert-manager

# Source yaml file containing the CRD
data "http" "cert_manager_crds" {
  url = var.cm_crds_url
}


# Decode the YAML content from the CRD manifest and split into individual documents
locals { cert_manager_crds_manifests = [for doc in split("---", data.http.cert_manager_crds.response_body) : yamldecode(doc)] }

# Apply each CRD manifest
resource "kubernetes_manifest" "cert_manager_crds" {
  for_each = {
    for idx, manifest in local.cert_manager_crds_manifests :
    "${manifest.kind}_${manifest.metadata.name}_${idx}" => manifest
  }

  manifest = each.value

}

# Ensure all Cert-Manager CRDs are applied before proceeding
resource "null_resource" "wait_for_cert_manager_crds" {
  provisioner "local-exec" {
    command = "sleep 30"
  }
  depends_on = [kubernetes_manifest.cert_manager_crds]
}

# Humio Operator CRDs
data "http" "humiocluster" {
  url = "https://raw.githubusercontent.com/humio/humio-operator/humio-operator-${var.humio_operator_version}/config/crd/bases/core.humio.com_humioclusters.yaml"
}

data "http" "humioexternalclusters" {
  url = "https://raw.githubusercontent.com/humio/humio-operator/humio-operator-${var.humio_operator_version}/config/crd/bases/core.humio.com_humioexternalclusters.yaml"
}

data "http" "humioingesttokens" {
  url = "https://raw.githubusercontent.com/humio/humio-operator/humio-operator-${var.humio_operator_version}/config/crd/bases/core.humio.com_humioingesttokens.yaml"
}

data "http" "humioparsers" {
  url = "https://raw.githubusercontent.com/humio/humio-operator/humio-operator-${var.humio_operator_version}/config/crd/bases/core.humio.com_humioparsers.yaml"
}

data "http" "humiorepositories" {
  url = "https://raw.githubusercontent.com/humio/humio-operator/humio-operator-${var.humio_operator_version}/config/crd/bases/core.humio.com_humiorepositories.yaml"
}

data "http" "humioviews" {
  url = "https://raw.githubusercontent.com/humio/humio-operator/humio-operator-${var.humio_operator_version}/config/crd/bases/core.humio.com_humioviews.yaml"
}

data "http" "humioalerts" {
  url = "https://raw.githubusercontent.com/humio/humio-operator/humio-operator-${var.humio_operator_version}/config/crd/bases/core.humio.com_humioalerts.yaml"
}

data "http" "humioactions" {
  url = "https://raw.githubusercontent.com/humio/humio-operator/humio-operator-${var.humio_operator_version}/config/crd/bases/core.humio.com_humioactions.yaml"
}

data "http" "humioscheduledsearches" {
  url = "https://raw.githubusercontent.com/humio/humio-operator/humio-operator-${var.humio_operator_version}/config/crd/bases/core.humio.com_humioscheduledsearches.yaml"
}

data "http" "humiofilteralerts" {
  url = "https://raw.githubusercontent.com/humio/humio-operator/humio-operator-${var.humio_operator_version}/config/crd/bases/core.humio.com_humiofilteralerts.yaml"
}

data "http" "humioaggregatealerts" {
  url = "https://raw.githubusercontent.com/humio/humio-operator/humio-operator-${var.humio_operator_version}/config/crd/bases/core.humio.com_humioaggregatealerts.yaml"
}

# Decode and filter out the 'status' attribute from the CRD manifests
locals {
  crds_manifests = flatten([
    for data in [
      data.http.humiocluster,
      data.http.humioexternalclusters,
      data.http.humioingesttokens,
      data.http.humioparsers,
      data.http.humiorepositories,
      data.http.humioviews,
      data.http.humioalerts,
      data.http.humioactions,
      data.http.humioscheduledsearches,
      data.http.humiofilteralerts,
      data.http.humioaggregatealerts
      ] : [
      { for k, v in yamldecode(data.response_body) : k => v if k != "status" }
    ]
  ])

  crds_map = {
    for idx, manifest in local.crds_manifests :
    "${manifest.kind}_${manifest.metadata.name}_${idx}" => manifest
  }
}



# Apply each CRD manifest
resource "kubernetes_manifest" "humio_operator_crds" {
  for_each = local.crds_map
  manifest = each.value

  depends_on = [var.cluster_endpoint]

}


# Ensure all Logscale CRDs are applied before proceeding
resource "null_resource" "wait_for_humio_operator_crds" {
  provisioner "local-exec" {
    command = "sleep 30"
  }
  depends_on = [kubernetes_manifest.humio_operator_crds]
}
