# ─────────────────────────────────────────────────────────────────────────────
# Provider
# ─────────────────────────────────────────────────────────────────────────────
variable "aws_region" {
  description = "AWS region to deploy resources into"
  type        = string
  default     = "ap-south-1"
}

# ─────────────────────────────────────────────────────────────────────────────
# Naming & tagging
# ─────────────────────────────────────────────────────────────────────────────
variable "cluster_name" {
  description = "Name for the EKS cluster and prefix for all related resources"
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource (merged with resource-specific tags)"
  type        = map(string)
  default     = {}
}

# ─────────────────────────────────────────────────────────────────────────────
# VPC
# ─────────────────────────────────────────────────────────────────────────────
variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (one per AZ)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (one per AZ)"
  type        = list(string)
  default     = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]
}

variable "availability_zones" {
  description = "Availability zones for the subnets"
  type        = list(string)
  default     = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]
}

variable "enable_nat_gateway" {
  description = "Provision a NAT Gateway so private nodes can reach the internet"
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "Use a single NAT Gateway across all AZs (cheaper; less resilient)"
  type        = bool
  default     = true
}

# ─────────────────────────────────────────────────────────────────────────────
# EKS cluster
# ─────────────────────────────────────────────────────────────────────────────
variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.32"
}

variable "service_ipv4_cidr_block" {
  description = "CIDR block for in-cluster Kubernetes Service IPs"
  type        = string
  default     = "172.20.0.0/16"
}

variable "endpoint_public_access" {
  description = "Enable public access to the Kubernetes API endpoint"
  type        = bool
  default     = true
}

variable "endpoint_private_access" {
  description = "Enable private (VPC-internal) access to the Kubernetes API endpoint"
  type        = bool
  default     = true
}

variable "public_access_cidrs" {
  description = "CIDR blocks that may access the public API endpoint"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "core_dns_version" {
  description = "CoreDNS addon version. Empty string = latest compatible version."
  type        = string
  default     = ""
}

variable "kube_proxy_version" {
  description = "kube-proxy addon version. Empty string = latest compatible version."
  type        = string
  default     = ""
}

variable "vpc_cni_version" {
  description = "VPC CNI addon version. Empty string = latest compatible version."
  type        = string
  default     = ""
}

variable "enable_irsa" {
  description = "Enable IAM Roles for Service Accounts (IRSA) via OIDC"
  type        = bool
  default     = true
}

# ─────────────────────────────────────────────────────────────────────────────
# Node groups
# Each entry becomes an aws_eks_node_group.  subnet_ids are injected
# automatically from the VPC module (private subnets).
# ─────────────────────────────────────────────────────────────────────────────
variable "node_groups" {
  description = "Map of EKS managed node group configurations"
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

# ─────────────────────────────────────────────────────────────────────────────
# Secrets Manager / API key
# ─────────────────────────────────────────────────────────────────────────────
variable "google_api_key" {
  description = <<-EOT
    Google / Gemini API key stored in AWS Secrets Manager.
    Pass via environment variable to avoid committing secrets:
      export TF_VAR_google_api_key="AIza..."
  EOT
  type        = string
  sensitive   = true
}

variable "backend_namespace" {
  description = "Kubernetes namespace where the backend service account lives"
  type        = string
  default     = "default"
}

variable "backend_service_account" {
  description = "Kubernetes service account name for the backend deployment"
  type        = string
  default     = "backend"
}
