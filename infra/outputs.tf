# ─────────────────────────────────────────────────────────────────────────────
# VPC
# ─────────────────────────────────────────────────────────────────────────────
output "vpc_id" {
  description = "ID of the VPC"
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "List of public subnet IDs"
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "List of private subnet IDs"
  value       = module.vpc.private_subnet_ids
}

# ─────────────────────────────────────────────────────────────────────────────
# EKS
# ─────────────────────────────────────────────────────────────────────────────
output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 certificate authority data (used by kubectl / helm)"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN (for additional IRSA roles)"
  value       = module.eks.oidc_provider_arn
}

output "oidc_provider_url" {
  description = "OIDC provider URL"
  value       = module.eks.oidc_provider_url
}

# ─────────────────────────────────────────────────────────────────────────────
# IAM
# ─────────────────────────────────────────────────────────────────────────────
output "cluster_role_arn" {
  description = "ARN of the EKS cluster IAM role"
  value       = module.iam.cluster_role_arn
}

output "node_group_role_arn" {
  description = "ARN of the EKS node group IAM role"
  value       = module.iam.node_group_role_arn
}

# ─────────────────────────────────────────────────────────────────────────────
# Secrets Manager
# ─────────────────────────────────────────────────────────────────────────────
output "api_key_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the API key"
  value       = module.secret_manager.secret_arn
}

output "api_key_secret_name" {
  description = "Name of the Secrets Manager secret (use as externalSecret.remoteSecretName in Helm)"
  value       = module.secret_manager.secret_name
}

output "backend_irsa_role_arn" {
  description = "ARN of the IRSA role to annotate on the backend Kubernetes service account"
  value       = module.secret_manager.backend_irsa_role_arn
}

# ─────────────────────────────────────────────────────────────────────────────
# ECR
# ─────────────────────────────────────────────────────────────────────────────
output "ecr_repository_url" {
  description = "Full ECR repository URL — use as image.repository in Helm values"
  value       = module.ecr.repository_url
}

output "ecr_repository_arn" {
  description = "ARN of the ECR repository"
  value       = module.ecr.repository_arn
}
