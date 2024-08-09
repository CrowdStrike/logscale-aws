variable "vpc_id" {
  description = "ID of the VPC where the EKS cluster will be provisioned"
  type        = string
}

variable "private_subnets" {
  description = "A list of CIDR blocks for private subnets."
  type        = list(string)
}

variable "intra_subnets" {
  description = "A list of intra subnets inside the VPC"
  type        = list(string)
}

variable "cluster_name" {
  description = "The name of the EKS cluster."
  type        = string
}

variable "cluster_version" {
  description = "The Kubernetes version for the EKS cluster."
  type        = string
}

variable "logscale_node_desired_capacity" {
  description = "The desired capacity for the logscale managed node group."
  type        = number
}

variable "logscale_node_max_capacity" {
  description = "The maximum capacity for the logscale managed node group."
  type        = number
}

variable "logscale_node_min_capacity" {
  description = "The minimum capacity for the logscale managed node group."
  type        = number
}

variable "logscale_instance_type" {
  description = "The instance type for the logscale managed node group."
  type        = string
}

variable "ami_type" {
  description = "The AMI type of the logscale managed node group."
  type        = string
}

variable "logscale_node_root_volume_size" {
  description = "The size of the root volume for the logscale managed node group."
  type        = number
}

variable "logscale_node_root_volume_type" {
  description = "The type of the root volume for the logscale managed node group."
  type        = string
}

# Ingress nodes
variable "ingress_node_desired_capacity" {
  description = "The desired capacity for the ingress managed node group."
  type        = number
}

variable "ingress_node_max_capacity" {
  description = "The maximum capacity for the ingress managed node group."
  type        = number
}

variable "ingress_node_min_capacity" {
  description = "The minimum capacity for the ingress managed node group."
  type        = number
}

variable "ingress_instance_type" {
  description = "The instance type for the ingress managed node group."
  type        = string
}

# Ingest nodes
variable "ingest_node_desired_capacity" {
  description = "The desired capacity for the ingest managed node group."
  type        = number
}

variable "ingest_node_max_capacity" {
  description = "The maximum capacity for the ingest managed node group."
  type        = number
}

variable "ingest_node_min_capacity" {
  description = "The minimum capacity for the ingest managed node group."
  type        = number
}

variable "ingest_instance_type" {
  description = "The instance type for the ingest managed node group."
  type        = string
}

# UI Nodes
variable "ui_node_desired_capacity" {
  description = "The desired capacity for the UI managed node group."
  type        = number
}

variable "ui_node_max_capacity" {
  description = "The maximum capacity for the UI managed node group."
  type        = number
}

variable "ui_node_min_capacity" {
  description = "The minimum capacity for the UI managed node group."
  type        = number
}

variable "ui_instance_type" {
  description = "The instance type for the UI managed node group."
  type        = string
}

variable "tags" {
  description = "map pf tags to be applied to AWS resources"
  type        = map(string)
}

variable "zone_name" {
  description = "Route53 hosted zone domain name"
  type        = string
}

variable "msk_sg_id" {
  description = "MKS Security group ID"
  type        = string
}

variable "hostname" {
  description = "Hostname of the Logscale cluster"
  type        = string
}

variable "route53_record_ttl" {
  description = "TTL of the Logscale route53 record"
  type        = number
}

variable "s3_bucket_prefix" {
  description = "The prefix of the LogScale S3 bucket"
  type        = string
  default     = ""
}

variable "user_data_script" {
  description = "EC2 instance user data script"
  type        = string
  default     = "user-data.sh.tmpl"
}

variable "humio_data_dir" {
  description = "Logscale data directory"
  type        = string
  default     = "/mnt/disks/vol1"
}

variable "humio_data_dir_owner_uuid" {
  description = "Owner uuid for the logscale data directory"
  type        = number
  default     = 65534
}

variable "logscale_iam_policy_description" {
  description = "The description used for the LogScale EKS cluster IAM policy"
  type        = string
  default     = "EKS logscale IAM policy for cluster"
}

variable "external_dns_iam_policy_description" {
  description = "The description used for the ExternalDNS IAM policy"
  type        = string
  default     = "ExternalDNS policy for managing Route53"
}

variable "cluster_enabled_log_types" {
  description = "The log types enabled for the EKS cluster"
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "cluster_endpoint_public_access" {
  description = "Determines whether the EKS cluster is publicly accessible"
  type        = bool
  default     = true
}

variable "logscale_cluster_type" {
  description = "Logscale cluster type"
  type        = string
  validation {
    condition     = contains(["basic", "ingress", "internal-ingest"], var.logscale_cluster_type)
    error_message = "logscale_cluster_type must be one of: basic, advanced, or internal-ingest"
  }
}

variable "logscale_ingest_data_disk_type" {
  description = "Logscale Ingest node disk type"
  type        = string
}

variable "logscale_ingest_root_disk_size" {
  description = "Logscale Ingest root disk size"
  type        = string
}

variable "logscale_ingest_root_disk_type" {
  description = "Logscale Ingest root disk type"
  type        = string
}

variable "logscale_ingest_data_disk_size" {
  description = "Logscale Ingest node disk size"
  type        = string
}

variable "logscale_ui_data_disk_size" {
  description = "Logscale UI node disk size"
  type        = string
}

variable "logscale_ui_data_disk_type" {
  description = "Logscale UI node disk type"
  type        = string
}

variable "logscale_ui_root_disk_size" {
  description = "Logscale UI root disk size"
  type        = string
}

variable "logscale_ui_root_disk_type" {
  description = "Logscale UI root disk type"
  type        = string
}
