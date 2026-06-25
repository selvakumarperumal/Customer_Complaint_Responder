variable "aws_region" {
  description = "AWS region name"
  type        = string
  default     = "ap-south-1"
}

variable "state_bucket_name_prefix" {
  description = "S3 bucket name prefix"
  type        = string
  default     = "ccr-tfstate-bucket-001"
}

variable "state_lock_table_name_prefix" {
  description = "DynamoDB table name prefix"
  type        = string
  default     = "ccr-tfstate-dynamodb-001"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnets_cidrs" {
  description = "Public subnets CIDR blocks"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "private_subnets_cidrs" {
  description = "Private subnets CIDR blocks"
  type        = list(string)
  default     = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "customer-complaint-responder"
}

variable "kubernetes_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.29"
}

variable "ecr_repository_names" {
  description = "List of ECR repository names"
  type        = list(string)
  default     = ["poller", "worker"]
}

variable "google_api_key" {
  description = "Google API Key for Worker Pods"
  type        = string
  sensitive   = true
}

variable "mistral_api_key" {
  description = "Mistral API Key for Worker Pods"
  type        = string
  sensitive   = true
}

variable "private_mail_password" {
  description = "Password for Namecheap Private Email"
  type        = string
  sensitive   = true
}

variable "private_mail_email_id" {
  description = "Namecheap Private Email ID"
  type        = string
  sensitive   = true
}

variable "private_mail_host" {
  description = "Namecheap Private Email host"
  type        = string
  default     = "mail.privateemail.com"
}

variable "imap_port" {
  description = "IMAP port"
  type        = string
  default     = "993"
}

variable "smtp_port" {
  description = "SMTP port"
  type        = string
  default     = "587"
}

variable "redis_stream_name" {
  description = "Redis stream name"
  type        = string
  default     = "email:inbound"
}

variable "redis_consumer_group_name" {
  description = "Redis consumer group name"
  type        = string
  default     = "ccr-complaint-worker"
}

# For future reference if using a private GitHub repository for ArgoCD GitOps
# variable "github_pat" {
#   description = "GitHub Personal Access Token for private GitOps repository"
#   type        = string
#   sensitive   = true
# }

