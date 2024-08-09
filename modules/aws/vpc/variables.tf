

variable "name" {
  description = "The name of the VPC."
  type        = string
}

variable "vpc_cidr" {
  description = "The CIDR block for the VPC."
  type        = string
}

variable "tags" {
  description = "map pf tags to be applied to AWS resources"
  type        = map(string)
}


variable "cluster_name" {
  description = "The name of the EKS cluster."
  type        = string
}


variable "msk_sg" {
  description = "Security Group name for MSK."
  type        = string
  default     = "msk_sg"
}
