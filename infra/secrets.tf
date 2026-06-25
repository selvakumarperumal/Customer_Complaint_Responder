resource "aws_secretsmanager_secret" "secrets" {
  name        = "${var.project_name}-secrets"
  description = "secrets for Worker Pods"

  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "api_key" {
  secret_id = aws_secretsmanager_secret.secrets.id

  secret_string = jsonencode({
    google_api_key        = var.google_api_key
    mistral_api_key       = var.mistral_api_key
    private_mail_email_id = var.private_mail_email_id
    private_mail_password = var.private_mail_password
  })
}

