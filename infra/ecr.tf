module "ecr" {
  source = "terraform-aws-modules/ecr/aws"

  for_each = toset(var.ecr_repository_names)

  repository_name                 = "${var.project_name}-ecr/${each.value}"
  repository_image_tag_mutability = "MUTABLE"
  repository_image_scan_on_push   = true

  repository_lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"

        action = {
          type = "expire"
        }

        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
      }
    ]
  })

}
