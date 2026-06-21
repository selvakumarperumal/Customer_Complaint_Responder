output "secret_arn" {
  description = "ARN of the Secrets Manager secret"
  value       = aws_secretsmanager_secret.api_key.arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret"
  value       = aws_secretsmanager_secret.api_key.name
}

output "backend_role_arn" {
  description = "ARN of the Pod Identity role for the backend / ESO service account"
  value       = var.enable_pod_identity ? aws_iam_role.backend_sa[0].arn : ""
}

output "backend_role_name" {
  description = "Name of the Pod Identity role (used to attach additional policies)"
  value       = var.enable_pod_identity ? aws_iam_role.backend_sa[0].name : ""
}
