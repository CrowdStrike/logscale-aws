variable "aws_region" {
  description = "The AWS region to create resources in."
  type        = string
}

variable "aws_profile" {
  description = "The AWS profile to use for the EKS cluster"
  type        = string
}

variable "cluster_endpoint" {
  description = "Endpoint for your Kubernetes API server"
  type        = string
}

variable "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data required to communicate with the cluster"
  type        = string
}

variable "cluster_name" {
  description = "The name of the EKS cluster."
  type        = string
}

variable "logscale_namespace" {
  description = "The namespace used by logscale."
  type        = string
}

variable "cm_namespace" {
  description = "The namespace used by cert-manager."
  type        = string

}

variable "cm_repo" {
  description = "The cert-manager repository."
  type        = string
}

variable "cm_version" {
  description = "The cert-manager helm chart version"
  type        = string
}

variable "logscale_operator_repo" {
  description = "The logscale repository."
  type        = string
}

variable "issuer_kind" {
  description = "Certificates issuer kind for the Logscale cluster."
  type        = string
}

variable "issuer_name" {
  description = "Certificates issuer name for the Logscale Cluster"
  type        = string
}

variable "issuer_email" {
  description = "Certificates issuer email for the Logscale Cluster"
  type        = string
}

variable "issuer_private_key" {
  description = "Certificates issuer private key for the Logscale Cluster"
  type        = string
}

variable "ca_server" {
  description = "Certificate Authority Server."
  type        = string
}

variable "humio_operator_chart_version" {
  description = "Humio Operator helm chart version"
  type        = string
}

variable "humio_operator_version" {
  description = "Humio Operator version"
  type        = string
}

variable "humio_operator_extra_values" {
  description = "Resource Management for logscale pods"
  type        = map(string)
}

variable "logscale_image_version" {
  description = "Logscale docker image version"
  type        = string
}

variable "logscale_cluster_type" {
  description = "Logscale cluster type"
  type        = string
  validation {
    condition     = contains(["basic", "ingress", "internal-ingest"], var.logscale_cluster_type)
    error_message = "logscale_cluster_type must be one of: basic, advanced, or internal-ingest"
  }
}

variable "zone_name" {
  description = "Route53 hosted zone domain name"
  type        = string
}

variable "acm_certificate_arn" {
  description = "ACM issued certificate ARN"
  type        = string
}

variable "logscale_s3_bucket_id" {
  description = "S3 bucket used by logscale"
  type        = string
}

variable "msk_bootstrap_brokers" {
  description = "Kafka bootstrap servers list"
  type        = string
}

variable "service_account_aws_iam_role_arn" {
  description = "Amazon Resource Name (ARN) for the service account role."
  type        = string
}

variable "alb_controller_repo" {
  description = "AWS Load balancer controller heklm chart repository."
  type        = string
  default     = "https://aws.github.io/eks-charts"
}

variable "eks_lb_controller_role_arn" {
  description = "ALB Controller IAM role"
  type        = string
}

variable "humiocluster_license" {
  description = "Logscale license"
  type        = string
}

variable "zookeeper_connect_string" {
  description = "Plain text connection host:port pairs for Zookeeper"
  type        = string
}

variable "hostname" {
  description = "Hostname of the Logscale cluster"
  type        = string
}

variable "logscale_digest_resources" {
  description = "Resource limits and requests for Logscale digest"
  type        = map(map(string))
}

variable "logscale_digest_node_count" {
  description = "Logscale digest node count"
  type        = number
}

variable "logscale_ingest_resources" {
  description = "Resource limits and requests for Logscale ingest"
  type        = map(map(string))
}


variable "logscale_ingress_resources" {
  description = "Resource limits and requests for Logscale ingress"
  type        = map(map(string))
}

variable "logscale_ingress_node_count" {
  description = "Logscale ingress node count"
  type        = number
}

variable "logscale_ui_resources" {
  description = "Resource limits and requests for Logscale UI"
  type        = map(map(string))
}

variable "logscale_ui_node_count" {
  description = "Logscale UI node count"
  type        = number
}

variable "logscale_ingest_node_count" {
  description = "Logscale Ingest-only node count"
  type        = number
}

variable "logscale_digest_data_disk_size" {
  description = "Logscale Digest node disk size"
  type        = string
}

variable "logscale_ingest_data_disk_size" {
  description = "Logscale Ingest node disk size"
  type        = string
}


variable "logscale_ingress_data_disk_size" {
  description = "Logscale Ingress node disk size"
  type        = string
}

variable "logscale_ui_data_disk_size" {
  description = "Logscale UI node disk size"
  type        = string
}

variable "external_dns_iam_role_arn" {
  description = "The ARN of the IAM role used by ExternalDNS"
  type        = string
}

variable "external_dns_chart_version" {
  description = "The version of the external-dns Helm chart to install"
  type        = string
  default     = "1.14.5"
}

variable "external_dns_repository" {
  description = "The Helm repository URL for the external-dns chart"
  type        = string
  default     = "https://kubernetes-sigs.github.io/external-dns/"
}
