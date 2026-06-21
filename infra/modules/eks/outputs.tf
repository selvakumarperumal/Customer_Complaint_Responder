output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "Endpoint of the EKS cluster API server"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded certificate authority data for the cluster"
  value       = aws_eks_cluster.main.certificate_authority[0].data
}

output "cluster_version" {
  description = "Kubernetes version of the cluster"
  value       = aws_eks_cluster.main.version
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC provider (kept for external OIDC federation e.g. GitHub Actions)"
  value       = var.enable_pod_identity ? aws_iam_openid_connect_provider.eks_oidc_provider[0].arn : ""
}

output "oidc_provider_url" {
  description = "URL of the OIDC provider"
  value       = var.enable_pod_identity ? aws_eks_cluster.main.identity[0].oidc[0].issuer : ""
}

output "cluster_security_group_id" {
  description = "ID of the EKS cluster security group"
  value       = aws_security_group.cluster.id
}

output "node_security_group_id" {
  description = "ID of the EKS node security group"
  value       = aws_security_group.node.id
}

output "kms_key_arn" {
  description = "ARN of the KMS key used for secrets encryption"
  value       = aws_kms_key.eks_kms_key.arn
}
