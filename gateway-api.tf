resource "kubernetes_manifest" "alb-config" {
  manifest = {
    apiVersion = "gateway.k8s.aws/v1beta1"
    kind       = "LoadBalancerConfiguration"
    metadata = {
      name      = "${var.cluster_name}-aws-alb-config"
      namespace = "${var.logscale_namespace}"
    }

    spec = {
      scheme = "internet-facing"
      listenerConfigurations = [{
        protocolPort = "HTTPS:443"
        defaultCertificate = module.eks.acm_certificate_arn
      }]
      defaultTargetGroupConfiguration = {
        name = kubernetes_manifest.target-group-config.manifest.metadata.name
      }
    }
  }
}

resource "kubernetes_manifest" "target-group-config" {
  manifest = {
    apiVersion = "gateway.k8s.aws/v1beta1"
    kind       = "TargetGroupConfiguration"
    metadata = {
      name      = "${var.cluster_name}-ls-default-target-group-config"
      namespace = "${var.logscale_namespace}"
    }

    spec = {
      defaultConfiguration = {
        targetType        = "ip"
        protocol          = "HTTPS"
        targetControlPort = "443"

        healthCheckConfig = {
          healthCheckPath         = "/api/v1/status"
          healthCheckTimeout      = "10"
          healthCheckInterval     = "15"
          healthyThresholdCount   = "2"
          unhealthyThresholdCount = "3"
          healthCheckProtocol     = "HTTPS"
        }
      }
    }
  }
}
