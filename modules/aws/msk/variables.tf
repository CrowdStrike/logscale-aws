
variable "broker_node_instance_type" {
  description = "Specify the instance type to use for the kafka brokers. e.g. kafka.m5.large. ([Pricing info](https://aws.amazon.com/msk/pricing/))"
  type        = string
}

variable "tags" {
  description = "A map of tags to assign to the resources created"
  type        = map(string)
}

variable "cluster_name" {
  description = "The name of the EKS cluster."
  type        = string
}

variable "private_subnets" {
  description = "A list of CIDR blocks for private subnets."
  type        = list(string)
}

variable "msk_cluster_name" {
  description = "Name of the MSK cluster"
  type        = string
}

variable "msk_sg_id" {
  description = "MSK security group ID."
  type        = string
}

variable "kafka_version" {
  description = "Specify the desired Kafka software version."
  type        = string
}

variable "msk_number_of_broker_nodes" {
  description = "Number of Kafka broker nodes."
  type        = number
}

variable "msk_node_volume_size" {
  description = "Kafka broker disk size."
  type        = number
}

variable "msk_log_retention_hours" {
  description = "Log retention time (in hours) for the MSK cluster"
  type        = number
  default     = 4
}
