terraform {
  required_version = ">= 1.15.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Secret — stores the Gemini / Google API key used by the backend
# The backend reads it via AliasChoices("GOOGLE_API_KEY", "GEMINI_API_KEY")
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_secretsmanager_secret" "api_key" {
  name                    = var.secret_name
  description             = "Google / Gemini API key for the CCR backend"
  recovery_window_in_days = 7

  tags = merge(var.tags, { Name = var.secret_name })
}

resource "aws_secretsmanager_secret_version" "api_key" {
  secret_id = aws_secretsmanager_secret.api_key.id

  # Stored as JSON so the backend can also fetch individual keys if needed.
  # The primary key name matches what pydantic-settings looks for.
  secret_string = jsonencode({
    GOOGLE_API_KEY = var.secret_value
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# IAM policy — allows reading this specific secret only
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_iam_policy" "read_api_key" {
  name        = "${var.cluster_name}-read-api-key-policy"
  description = "Allows GetSecretValue on the CCR API key secret"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
        ]
        Resource = aws_secretsmanager_secret.api_key.arn
      }
    ]
  })

  tags = var.tags
}

# ─────────────────────────────────────────────────────────────────────────────
# IRSA role — lets the backend Kubernetes service account assume this role
# so the pod can call Secrets Manager without long-lived credentials
# ─────────────────────────────────────────────────────────────────────────────
locals {
  # Strip the https:// prefix — the OIDC condition key uses the bare URL
  oidc_url = replace(var.oidc_provider_url, "https://", "")
}

resource "aws_iam_role" "backend_sa" {
  count = var.enable_irsa ? 1 : 0

  name        = "${var.cluster_name}-backend-sa-role"
  description = "IRSA role for the CCR backend service account"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Federated = var.oidc_provider_arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${local.oidc_url}:sub" = "system:serviceaccount:${var.namespace}:${var.service_account_name}"
            "${local.oidc_url}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = merge(var.tags, { Name = "${var.cluster_name}-backend-sa-role" })
}

resource "aws_iam_role_policy_attachment" "backend_sa_read_secret" {
  count = var.enable_irsa ? 1 : 0

  role       = aws_iam_role.backend_sa[0].name
  policy_arn = aws_iam_policy.read_api_key.arn
}
