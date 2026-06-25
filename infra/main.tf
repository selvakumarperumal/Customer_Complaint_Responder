
data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {}

terraform {
  backend "s3" {
    bucket       = "${var.state_bucket_name_prefix}-${data.aws_caller_identity.current.account_id}"
    key          = "infra/terraform.tfstate"
    region       = var.aws_region
    use_lockfile = true
    lock_table   = "${var.state_lock_table_name_prefix}-${data.aws_caller_identity.current.account_id}"
  }
}

locals {
  cluster_name = "${var.project_name}-cluster"
}
