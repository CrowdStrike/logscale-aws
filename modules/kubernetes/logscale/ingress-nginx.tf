# AWS ELB Ingress Controller
resource "kubernetes_service_account" "aws_lb_controller" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = var.eks_lb_controller_role_arn
    }
  }
}

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
    name  = "source"
    value = "ingress"
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
}

resource "helm_release" "aws_lb_controller" {
  name       = "aws-load-balancer-controller-${var.cluster_name}"
  repository = var.alb_controller_repo
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.8.1"

  set {
    name  = "clusterName"
    value = var.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "false"
  }

  set {
    name  = "serviceAccount.name"
    value = kubernetes_service_account.aws_lb_controller.metadata[0].name
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = var.eks_lb_controller_role_arn
  }

  set {
    name  = "cluster.dnsDomain"
    value = "${var.hostname}.${var.zone_name}"
  }

}

resource "kubernetes_service" "logscale_basic_nodeport" {
  count = contains(["basic"], var.logscale_cluster_type) ? 1 : 0

  metadata {
    name      = "${var.cluster_name}-nodeport"
    namespace = kubernetes_namespace.logscale.metadata[0].name
  }

  spec {
    selector = {
      "app.kubernetes.io/name" = "humio"
    }
    port {
      port        = 8080
      target_port = 8080
      name        = "logscale-port"
    }
    type = "NodePort"
  }

  depends_on = [
    helm_release.cert_manager,
    kubernetes_manifest.humio_cluster_type_basic[0],
    helm_release.aws_lb_controller

  ]
}

resource "kubernetes_ingress_v1" "logscale_basic_ingress" {
  count = contains(["basic"], var.logscale_cluster_type) ? 1 : 0
  metadata {
    name      = "${var.cluster_name}-basic-ingress"
    namespace = kubernetes_namespace.logscale.metadata[0].name
    annotations = {
      "kubernetes.io/ingress.class"                            = "alb"
      "alb.ingress.kubernetes.io/scheme"                       = "internet-facing"
      "alb.ingress.kubernetes.io/listen-ports"                 = jsonencode([{ HTTPS = 443 }])
      "alb.ingress.kubernetes.io/backend-protocol"             = "HTTPS"
      "alb.ingress.kubernetes.io/certificate-arn"              = var.acm_certificate_arn
      "alb.ingress.kubernetes.io/target-type"                  = "ip"
      "alb.ingress.kubernetes.io/healthcheck-path"             = "/api/v1/status"
      "alb.ingress.kubernetes.io/healthcheck-interval-seconds" = "15"
      "alb.ingress.kubernetes.io/healthcheck-timeout-seconds"  = "10"
      "alb.ingress.kubernetes.io/healthy-threshold-count"      = "2"
      "alb.ingress.kubernetes.io/unhealthy-threshold-count"    = "3"
      "alb.ingress.kubernetes.io/healthcheck-protocol"         = "HTTPS"
      "external-dns.alpha.kubernetes.io/hostname"              = "${var.hostname}.${var.zone_name}"
      "external-dns.alpha.kubernetes.io/alias"                 = "true"
      "external-dns.alpha.kubernetes.io/ttl"                   = "300"
    }
  }
  spec {
    default_backend {
      service {
        name = kubernetes_service.logscale_basic_nodeport[0].metadata[0].name
        port {
          number = 8080
        }
      }
    }
    rule {
      http {
        path {
          path = "/"
          backend {
            service {
              name = kubernetes_service.logscale_basic_nodeport[0].metadata[0].name
              port {
                number = 8080
              }
            }
          }
        }
      }
    }
  }

  depends_on = [
    # Ensure this ingress depends on other relevant resources being up.
    kubernetes_manifest.humio_cluster_type_basic[0],
    helm_release.aws_lb_controller
  ]
}


resource "kubernetes_service" "logscale_nodeport_ingress" {
  count = contains(["ingress"], var.logscale_cluster_type) ? 1 : 0
  metadata {
    name      = "${var.cluster_name}-nodeport-ingress"
    namespace = kubernetes_namespace.logscale.metadata[0].name
  }
  spec {
    selector = {
      "humio.com/node-pool" = "${var.cluster_name}-ingress-only"
    }
    port {
      port        = 8080
      target_port = 8080
      name        = "logscale-port"
    }
    type = "NodePort"
  }
  depends_on = [
    kubernetes_manifest.humio_cluster_type_ingress[0],
    helm_release.aws_lb_controller
  ]
}

# Kubernetes Ingress for routing external traffic to the NodePort Service
resource "kubernetes_ingress_v1" "logscale_ingress" {
  count = contains(["ingress"], var.logscale_cluster_type) ? 1 : 0
  metadata {
    name      = "${var.cluster_name}-ingress"
    namespace = kubernetes_namespace.logscale.metadata[0].name
    annotations = {
      "kubernetes.io/ingress.class"                            = "alb"
      "alb.ingress.kubernetes.io/scheme"                       = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"                  = "ip"
      "alb.ingress.kubernetes.io/listen-ports"                 = jsonencode([{ HTTPS = 443 }])
      "alb.ingress.kubernetes.io/ssl-redirect"                 = "443"
      "alb.ingress.kubernetes.io/backend-protocol"             = "HTTPS"
      "alb.ingress.kubernetes.io/certificate-arn"              = var.acm_certificate_arn
      "alb.ingress.kubernetes.io/healthcheck-path"             = "/api/v1/status"
      "alb.ingress.kubernetes.io/healthcheck-interval-seconds" = "15"
      "alb.ingress.kubernetes.io/healthcheck-timeout-seconds"  = "10"
      "alb.ingress.kubernetes.io/healthy-threshold-count"      = "2"
      "alb.ingress.kubernetes.io/unhealthy-threshold-count"    = "3"
      "alb.ingress.kubernetes.io/healthcheck-protocol"         = "HTTPS"
      "external-dns.alpha.kubernetes.io/hostname"              = "${var.hostname}.${var.zone_name}"
      "external-dns.alpha.kubernetes.io/alias"                 = "true"
      "external-dns.alpha.kubernetes.io/ttl"                   = "300"
    }
  }
  spec {
    default_backend {
      service {
        name = kubernetes_service.logscale_nodeport_ingress[0].metadata[0].name
        port {
          number = 8080
        }
      }
    }
    rule {
      http {
        path {
          backend {
            service {
              name = kubernetes_service.logscale_nodeport_ingress[0].metadata[0].name
              port {
                number = 8080
              }
            }
          }
        }
      }
    }
  }
  depends_on = [
    kubernetes_manifest.humio_cluster_type_ingress[0],
    helm_release.aws_lb_controller
  ]
}


# Kubernetes Service for UI
resource "kubernetes_service" "logscale_nodeport_ui" {
  count = contains(["internal-ingest"], var.logscale_cluster_type) ? 1 : 0
  metadata {
    name      = "${var.cluster_name}-nodeport-ui"
    namespace = kubernetes_namespace.logscale.metadata[0].name
  }
  spec {
    selector = {
      "humio.com/node-pool" = "${var.cluster_name}-ui-only"
    }
    port {
      port        = 8080
      target_port = 8080
      name        = "logscale-port"
    }
    type = "NodePort"
  }
  depends_on = [
    kubernetes_manifest.humio_cluster_type_internal_ingest[0],
    helm_release.aws_lb_controller
  ]
}

resource "kubernetes_ingress_v1" "logscale_ingress_ui" {
  count = contains(["internal-ingest"], var.logscale_cluster_type) ? 1 : 0
  metadata {
    name      = "${var.cluster_name}-ui-ingress"
    namespace = kubernetes_namespace.logscale.metadata[0].name
    annotations = {
      "kubernetes.io/ingress.class"                            = "alb"
      "alb.ingress.kubernetes.io/scheme"                       = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"                  = "ip"
      "alb.ingress.kubernetes.io/listen-ports"                 = jsonencode([{ HTTPS = 443 }])
      "alb.ingress.kubernetes.io/ssl-redirect"                 = "443"
      "alb.ingress.kubernetes.io/certificate-arn"              = var.acm_certificate_arn
      "alb.ingress.kubernetes.io/target-type"                  = "ip"
      "alb.ingress.kubernetes.io/healthcheck-path"             = "/api/v1/status/"
      "alb.ingress.kubernetes.io/healthcheck-interval-seconds" = "15"
      "alb.ingress.kubernetes.io/healthcheck-timeout-seconds"  = "10"
      "alb.ingress.kubernetes.io/healthy-threshold-count"      = "2"
      "alb.ingress.kubernetes.io/unhealthy-threshold-count"    = "3"
      "alb.ingress.kubernetes.io/healthcheck-protocol"         = "HTTPS"
      "alb.ingress.kubernetes.io/backend-protocol"             = "HTTPS"
      "external-dns.alpha.kubernetes.io/hostname"              = "${var.hostname}.${var.zone_name}"
      "external-dns.alpha.kubernetes.io/alias"                 = "true"
      "external-dns.alpha.kubernetes.io/ttl"                   = "300"
    }
  }
  spec {
    default_backend {
      service {
        name = kubernetes_service.logscale_nodeport_ui[0].metadata[0].name
        port {
          number = 8080
        }
      }
    }
    rule {
      http {
        path {
          backend {
            service {
              name = kubernetes_service.logscale_nodeport_ui[0].metadata[0].name
              port {
                number = 8080
              }
            }
          }
        }
      }
    }
  }
  depends_on = [
    kubernetes_manifest.humio_cluster_type_internal_ingest[0],
    helm_release.aws_lb_controller
  ]
}

# Kubernetes Service for Ingest
resource "kubernetes_service" "logscale_nodeport_ingest" {
  count = contains(["internal-ingest"], var.logscale_cluster_type) ? 1 : 0
  metadata {
    name      = "${var.cluster_name}-nodeport-ingest"
    namespace = kubernetes_namespace.logscale.metadata[0].name
  }
  spec {
    selector = {
      "humio.com/node-pool" = "${var.cluster_name}-ingest-only"
    }
    port {
      port        = 8080
      target_port = 8080
      name        = "logscale-port"
    }
    type = "NodePort"
  }
  depends_on = [
    kubernetes_manifest.humio_cluster_type_internal_ingest[0],
    helm_release.aws_lb_controller
  ]
}

resource "kubernetes_ingress_v1" "logscale_ingress_ingest" {
  count = contains(["internal-ingest"], var.logscale_cluster_type) ? 1 : 0
  metadata {
    name      = "${var.cluster_name}-ingest-ingress"
    namespace = kubernetes_namespace.logscale.metadata[0].name
    annotations = {
      "kubernetes.io/ingress.class"                            = "alb"
      "alb.ingress.kubernetes.io/scheme"                       = "internal"
      "alb.ingress.kubernetes.io/target-type"                  = "ip"
      "alb.ingress.kubernetes.io/listen-ports"                 = jsonencode([{ HTTPS = 443 }])
      "alb.ingress.kubernetes.io/certificate-arn"              = var.acm_certificate_arn
      "alb.ingress.kubernetes.io/backend-protocol"             = "HTTPS"
      "alb.ingress.kubernetes.io/ssl-redirect"                 = "443"
      "alb.ingress.kubernetes.io/healthcheck-path"             = "/api/v1/status/"
      "alb.ingress.kubernetes.io/healthcheck-interval-seconds" = "15"
      "alb.ingress.kubernetes.io/healthcheck-timeout-seconds"  = "10"
      "alb.ingress.kubernetes.io/healthy-threshold-count"      = "2"
      "alb.ingress.kubernetes.io/unhealthy-threshold-count"    = "3"
      "alb.ingress.kubernetes.io/healthcheck-protocol"         = "HTTPS"
    }
  }
  spec {
    default_backend {
      service {
        name = kubernetes_service.logscale_nodeport_ingest[0].metadata[0].name
        port {
          number = 8080
        }
      }
    }
    rule {
      http {
        path {
          path = "/"
          backend {
            service {
              name = kubernetes_service.logscale_nodeport_ingest[0].metadata[0].name
              port {
                number = 8080
              }
            }
          }
        }
      }
    }
    tls {
      secret_name = "${var.cluster_name}-internal-ingest"
    }

  }
  depends_on = [
    kubernetes_manifest.humio_cluster_type_internal_ingest[0],
    helm_release.aws_lb_controller
  ]
}

resource "kubernetes_manifest" "logscale_internal_ingest_cert" {
  count = contains(["internal-ingest"], var.logscale_cluster_type) ? 1 : 0
  manifest = {
    "apiVersion" = "cert-manager.io/v1"
    "kind"       = "Certificate"
    "metadata" = {
      "name"      = "${var.cluster_name}-internal-ingest"
      "namespace" = kubernetes_namespace.logscale.metadata[0].name
      "labels" = {
        "app.kubernetes.io/instance"   = "humiocluster"
        "app.kubernetes.io/managed-by" = "terraform"
        "app.kubernetes.io/name"       = "humio"
        "humio.com/node-pool"          = "${var.cluster_name}-ingest-only"
      }
    }
    "spec" = {
      "dnsNames" = [
        "${var.cluster_name}-internal-ingest.logging",
        "${var.cluster_name}-internal-ingest-headless.logging",
      ]
      "issuerRef" = {
        "name" = "humiocluster"
      }
      "secretName" = "${var.cluster_name}-internal-ingest"
    }
  }
  depends_on = [
    kubernetes_manifest.humio_cluster_type_internal_ingest[0]
  ]
}
