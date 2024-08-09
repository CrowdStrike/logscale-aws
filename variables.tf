variable "aws_region" {
  description = "The AWS region to create resources in."
  type        = string
}

variable "aws_profile" {
  description = "The AWS profile to use for the EKS cluster"
  type        = string
}

variable "tags" {
  description = "map pf tags to be applied to AWS resources"
  type        = map(string)
}

variable "vpc_name" {
  description = "The name of the VPC."
  type        = string
}


variable "vpc_cidr" {
  description = "The CIDR block for the VPC."
  type        = string
}


variable "cluster_name" {
  description = "The name of the EKS cluster."
  type        = string
}

variable "cluster_version" {
  description = "The Kubernetes version for the EKS cluster."
  type        = string
}

variable "ami_type" {
  description = "The AMI type of the logscale managed node group."
  type        = string
}

variable "route53_record_ttl" {
  description = "TTL of the Logscale route53 record"
  type        = number
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

variable "logscale_image_version" {
  description = "Logscale docker image version"
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
  default     = "0.20.3"
  type        = string
}

variable "humio_operator_extra_values" {
  description = "Resource Management for logscale pods"
  type        = map(string)
}

variable "logscale_cluster_type" {
  description = "Logscale cluster type"
  type        = string
  validation {
    condition     = contains(["basic", "ingress", "internal-ingest"], var.logscale_cluster_type)
    error_message = "logscale_cluster_type must be one of: basic, advanced, or internal-ingest"
  }
}

variable "logscale_cluster_size" {
  description = "Logscale cluster size"
  default     = "xsmall"
  type        = string
  validation {
    condition     = contains(["xsmall", "small", "medium", "large", "xlarge"], var.logscale_cluster_size)
    error_message = "logscale_cluster_size must be one of: xsmall, small, medium, large, or xlarge"
  }
}

variable "kafka_version" {
  description = "Specify the desired Kafka software version"
  type        = string
}

variable "msk_cluster_name" {
  description = "Name of the MSK cluster"
  type        = string
}

variable "zone_name" {
  description = "Route53 hosted zone domain name"
  type        = string
}

variable "humiocluster_license" {
  description = "Logscale license"
  type        = string
}

variable "hostname" {
  description = "Hostname of the Logscale cluster"
  type        = string
}

variable "eks_s3_bucket_prefix" {
  description = "The prefix of the LogScale S3 bucket"
  type        = string
  default     = ""
}
