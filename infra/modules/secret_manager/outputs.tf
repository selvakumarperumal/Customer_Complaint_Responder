output "secret_arn" {
  description = "ARN of the Secrets Manager secret"
  value       = aws_secretsmanager_secret.api_key.arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret"
  value       = aws_secretsmanager_secret.api_key.name
}

output "backend_irsa_role_arn" {
  description = "ARN of the IRSA role for the backend service account (empty if IRSA disabled)"
  value       = var.enable_irsa ? aws_iam_role.backend_sa[0].arn : ""
}

output "backend_irsa_role_name" {
  description = "Name of the IRSA role for the backend service account (empty if IRSA disabled)"
  value       = var.enable_irsa ? aws_iam_role.backend_sa[0].name : ""
}
