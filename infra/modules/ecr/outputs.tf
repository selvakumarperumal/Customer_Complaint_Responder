output "repository_url" {
  description = "Full ECR repository URL (use as image.repository in Helm values)"
  value       = aws_ecr_repository.backend.repository_url
}

output "repository_arn" {
  description = "ARN of the ECR repository"
  value       = aws_ecr_repository.backend.arn
}

output "registry_id" {
  description = "AWS account ID (ECR registry ID)"
  value       = aws_ecr_repository.backend.registry_id
}

output "ecr_pull_policy_arn" {
  description = "ARN of the IAM policy that allows pulling images from this repo"
  value       = aws_iam_policy.ecr_pull.arn
}
