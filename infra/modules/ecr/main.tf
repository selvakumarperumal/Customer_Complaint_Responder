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
# ECR repository
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_ecr_repository" "backend" {
  name                 = var.repository_name
  image_tag_mutability = var.image_tag_mutability

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(var.tags, { Name = var.repository_name })
}

resource "aws_ecr_lifecycle_policy" "backend" {
  repository = aws_ecr_repository.backend.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 release images (v* tags)"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v"]
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      }
    ]
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# IAM policy — allows pulling images from this specific repository.
# Attached to the backend IRSA role in the root module so the service account
# can authenticate with ECR (GetAuthorizationToken) and pull image layers.
# Node-level pulls via the node group role also remain in place.
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_iam_policy" "ecr_pull" {
  name        = "${var.cluster_name}-ecr-pull"
  description = "Allow the backend service account to pull images from ECR"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRPullImage"
        Effect = "Allow"
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
          "ecr:DescribeImages",
          "ecr:ListImages"
        ]
        Resource = aws_ecr_repository.backend.arn
      },
      {
        Sid      = "ECRGetToken"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      }
    ]
  })

  tags = var.tags
}
