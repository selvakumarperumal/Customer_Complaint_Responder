resource "aws_ssm_parameter" "imap_port" {
  name  = "/${var.project_name}/imap_port"
  type  = "String"
  value = var.imap_port
}

resource "aws_ssm_parameter" "smtp_port" {
  name  = "/${var.project_name}/smtp_port"
  type  = "String"
  value = var.smtp_port
}

resource "aws_ssm_parameter" "redis_stream_name" {
  name  = "/${var.project_name}/redis_stream_name"
  type  = "String"
  value = var.redis_stream_name
}

resource "aws_ssm_parameter" "redis_consumer_group_name" {
  name  = "/${var.project_name}/redis_consumer_group_name"
  type  = "String"
  value = var.redis_consumer_group_name
}

resource "aws_ssm_parameter" "private_mail_host" {
  name  = "/${var.project_name}/private_mail_host"
  type  = "String"
  value = var.private_mail_host
}

resource "aws_ssm_parameter" "ecr_image_repo_prefix" {
  name  = "/${var.project_name}/ecr_image_repo_prefix"
  type  = "String"
  value = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}
