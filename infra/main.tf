data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {}

terraform {
  backend "s3" {}
}

locals {
  cluster_name = "${var.project_name}-cluster"
}
