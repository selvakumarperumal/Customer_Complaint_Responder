
data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {}

terraform {
  backend "s3" {
    # Backend configuration cannot contain variables or data sources.
    # Initialize using a backend config file:
    #   terraform init -backend-config=backend.conf
    #
    # Or pass them via command-line arguments:
    #   terraform init \
    #     -backend-config="bucket=ccr-tfstate-bucket-001-<ACCOUNT_ID>" \
    #     -backend-config="key=infra/terraform.tfstate" \
    #     -backend-config="region=ap-south-1" \
    #     -backend-config="dynamodb_table=ccr-tfstate-dynamodb-001-<ACCOUNT_ID>"
  }
}

locals {
  cluster_name = "${var.project_name}-cluster"
}
