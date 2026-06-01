variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "vpc_id" {
  description = "ID of the VPC where the EKS cluster will be deployed"
  type        = string
}

variable "service_ipv4_cidr_block" {
  description = "CIDR block for Kubernetes service IPs"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
}

variable "cluster_role_arn" {
  description = "ARN of the IAM role for the EKS cluster"
  type        = string
}

variable "node_group_role_arn" {
  description = "ARN of the IAM role for the EKS node group"
  type        = string
}

variable "endpoint_public_access" {
  description = "Whether to enable public access to the EKS API endpoint"
  type        = bool
  default     = true
}

variable "endpoint_private_access" {
  description = "Whether to enable private access to the EKS API endpoint"
  type        = bool
  default     = false
}

variable "public_access_cidrs" {
  description = "CIDR blocks allowed to access the public EKS API endpoint"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "node_groups" {
  description = "Map of node group configurations keyed by name"
  type = map(object({
    instance_types = list(string)
    desired_size   = number
    min_size       = number
    max_size       = number
    capacity_type  = optional(string, "ON_DEMAND")
    labels         = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = string
      effect = string
    })), [])
    tags = optional(map(string), {})
  }))
}

variable "core_dns_version" {
  description = "Version of CoreDNS to use in the EKS cluster"
  type        = string
}

variable "kube_proxy_version" {
  description = "Version of kube-proxy to use in the EKS cluster"
  type        = string
}

variable "vpc_cni_version" {
  description = "Version of the VPC CNI plugin to use in the EKS cluster"
  type        = string
}

variable "vpc_cni_role_arn" {
  description = "ARN of the IAM role for the VPC CNI plugin"
  type        = string
}

variable "enable_irsa" {
  description = "Enable IAM Roles for Service Accounts (IRSA)"
  type        = bool
  default     = true
}

variable "subnet_ids" {
  description = "Subnet IDs for the EKS cluster control plane (combine public + private)"
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Private subnet IDs used by all node groups"
  type        = list(string)
}

variable "enable_detailed_monitoring" {
  description = "Enable detailed CloudWatch monitoring for EC2 nodes"
  type        = bool
  default     = false
}

